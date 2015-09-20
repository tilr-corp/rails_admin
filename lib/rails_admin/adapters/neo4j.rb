require 'neo4j'

require 'kaminari/neo4j'
require 'rails_admin/adapters/neo4j/active_rel_ext'

require 'rails_admin/config/sections/list'
require 'rails_admin/adapters/neo4j/abstract_object'
require 'rails_admin/adapters/neo4j/association'
require 'rails_admin/adapters/neo4j/property'

module RailsAdmin
  module Adapters
    module Neo4j
      DISABLED_COLUMN_TYPES = []
      # ObjectId = defined?(Moped::BSON) ? Moped::BSON::ObjectId : BSON::ObjectId # rubocop:disable ConstantName

      def new(params = {})
        AbstractObject.new(model.new(params))
      end

      def get(id)
        AbstractObject.new(model.find(id))
      end

      def scoped
        if model.ancestors.include?(::Neo4j::ActiveRel)
          ::Neo4j::ActiveRel::ActiveRelQueryProxy.new(model, model.send(:all_query))
        else
          model.all
        end
      end

      def first(options = {}, scope = nil)
        all(options, scope).first
      end

      def all(options = {}, scope = nil)
        scope ||= scoped
        #scope = scope.with_associations(*options[:include]) if options[:include]
        scope = scope.limit(options[:limit]) if options[:limit]
        scope = scope.where(primary_key => options[:bulk_ids]) if options[:bulk_ids]
        scope = query_scope(scope, options[:query]) if options[:query]

        if options[:filters]
          filter_conditions(options[:filters]).each do |condition|
            scope = scope.where(condition)
          end
        end
        scope = sort_by(options, scope) if options[:sort]
        if options[:page] && options[:per] && !scope.is_a?(Array)
          scope = scope.send(Kaminari.config.page_method_name, options[:page]).per(options[:per])
        end
        scope
      end

      def count(options = {}, scope = nil)
        all(options.merge(limit: false, page: false), scope).count
      end

      def destroy(objects)
        Array.wrap(objects).each(&:destroy)
      end

      def primary_key
        'uuid'
      end

      def associations
        return [] if model.ancestors.include?(::Neo4j::ActiveRel)

        model.associations.values.collect do |association|
          Association.new(association, model)
        end
      end

      def properties
        model.attributes.collect do |_name, attribute_definition|
          Property.new(attribute_definition, model)
        end
      end

      def table_name
        if model.ancestors.include?(::Neo4j::ActiveNode)
          model.mapped_label_names[0].to_s
        else
          model.class.to_s
        end
      end

      def encoding
        'UTF-8'
      end

      def embedded?
        false
      end

      def cyclic?
        # model.cyclic?
        false
      end

      def adapter_supports_joins?
        false
      end

      class WhereBuilder
        def initialize(scope)
          @statements = []
          @values = []
          @tables = []
          @scope = scope
        end

        def add(field, value, operator)
          field.searchable_columns.flatten.each do |column_infos|
            column = 'n.' + column_infos[:column].split('.')[1]
            statement, value1, value2 = StatementBuilder.new(column, column_infos[:type], value, operator).to_statement
            @statements << statement if statement.present?
            @values += [value1, value2].compact
            table, column = column_infos[:column].split('.')
            @tables.push(table) if column
          end
        end

        def build
          statements_string = @statements.join(' OR ')

          i = 0
          params = {}
          statements_string.gsub!(/\?/) do
            param_name = "query_param_#{i}"
            params[param_name] = @values[i]
            i += 1
            "{#{param_name}}"
          end

          @scope.where(statements_string).params(params)
        end
      end

    private

      def build_statement(column, type, value, operator)
        StatementBuilder.new(column, type, value, operator).to_statement
      end

      def make_field_conditions(field, value, operator)
        conditions_per_collection = {}
        require 'pry'
        binding.pry
        field.searchable_columns.each do |column_infos|
          label, property_name = parse_column_name(column_infos[:column])
          statement = build_statement(property_name, column_infos[:type], value, operator)
          next unless statement
          conditions_per_collection[label] ||= []
          conditions_per_collection[label] << statement
        end
        conditions_per_collection
      end

      def query_scope(scope, query, fields = config.list.fields.select(&:queryable?))
        wb = WhereBuilder.new(scope)
        fields.each do |field|
          wb.add(field, query, field.search_operator)
        end
        # OR all query statements
        wb.build
      end

      # filters example => {"string_field"=>{"0055"=>{"o"=>"like", "v"=>"test_value"}}, ...}
      # "0055" is the filter index, no use here. o is the operator, v the value
      def filter_conditions(filters, fields = config.list.fields.select(&:filterable?))
        statements = []

        filters.each_pair do |field_name, filters_dump|
          filters_dump.each do |_, filter_dump|
            field = fields.detect { |f| f.name.to_s == field_name }
            next unless field
            conditions_per_collection = make_field_conditions(field, filter_dump[:v], (filter_dump[:o] || 'default'))
            field_statements = make_condition_for_current_collection(field, conditions_per_collection)
            if field_statements.many?
              statements << {'$or' => field_statements}
            elsif field_statements.any?
              statements << field_statements.first
            end
          end
        end

        if statements.any?
          statements
        else
          []
        end
      end

      def parse_column_name(column)
        label, property_name = column.split('.')
        # if [:embeds_one, :embeds_many].include?(model.relations[label].try(:macro).try(:to_sym))
        [label, property_name]
        # else
        #  [label, property_name]
        # end
      end

      def make_condition_for_current_collection(target_field, conditions_per_collection)
        result = []
        conditions_per_collection.each do |label, conditions|
          if label == table_name
            # conditions referring current model column are passed directly
            result.concat conditions
          else
            # otherwise, collect ids of documents that satisfy search condition
            require 'pry'
            binding.pry
            result.concat perform_search_on_associated_collection(target_field.name, conditions)
          end
        end
        result
      end

      def perform_search_on_associated_collection(field_name, conditions)
        target_association = associations.detect { |a| a.name == field_name }
        return [] unless target_association
        model = target_association.klass
        case target_association.type
        when :has_one
          [{target_association.foreign_key.to_s => {'$in' => model.where('$or' => conditions).all.collect { |r| r.send(target_association.primary_key) }}}]
        when :has_many
          [{target_association.primary_key.to_s => {'$in' => model.where('$or' => conditions).all.collect { |r| r.send(target_association.foreign_key) }}}]
        end
      end

      def sort_by(options, scope)
        return scope unless options[:sort]

        case options[:sort]
        when String
          label, property_name = parse_column_name(options[:sort])
          if label && label != table_name
            fail('sorting by associated model column is not supported in Non-Relational databases')
          end
        when Symbol
          property_name = options[:sort].to_s
        end

        if scope.is_a?(Array)
          result = scope.sort_by(&property_name.to_sym)
          result = result.reverse if options[:sort_reverse]
          result
        else
          scope.order(property_name => options[:sort_reverse] ? :asc : :desc)
        end
      end

      class StatementBuilder < RailsAdmin::AbstractModel::StatementBuilder
      protected

        def unary_operators
          {
            '_blank' => ["(#{@column} IS NULL OR #{@column} = '')"],
            '_present' => ["(#{@column} IS NOT NULL AND #{@column} != '')"],
            '_null' => ["(#{@column} IS NULL)"],
            '_not_null' => ["(#{@column} IS NOT NULL)"],
            '_empty' => ["(#{@column} = '')"],
            '_not_empty' => ["(#{@column} != '')"],
          }
        end

      private

        def range_filter(min, max)
          if min && max
            {@column => (min..max)}
          elsif min
            ["(n.#{@column} >= ?)", min]
          elsif max
            ["(n.#{@column} <= ?)", max]
          end
        end

        def build_statement_for_type
          case @type
          when :boolean                   then build_statement_for_boolean
          when :integer, :decimal, :float then build_statement_for_integer_decimal_or_float
          when :string, :text             then build_statement_for_string_or_text
          when :enum                      then build_statement_for_enum
          when :belongs_to_association    then build_statement_for_belongs_to_association
          end
        end

        def build_statement_for_boolean
          return ["(n.#{@column} IS NULL OR n.#{@column} = ?)", false] if %w(false f 0).include?(@value)
          return ["(n.#{@column} = ?)", true] if %w(true t 1).include?(@value)
        end

        def column_for_value(value)
          ["(n.#{@column} = ?)", value]
        end

        def build_statement_for_belongs_to_association
          return if @value.blank?
          ["(#{@column} = ?)", @value.to_i] if @value.to_i.to_s == @value
        end

        def build_statement_for_string_or_text
          return if @value.blank?
          @value = begin
            case @operator
            when 'default', 'like'
              ".*#{@value.downcase}.*"
            when 'starts_with'
              "#{@value.downcase}.*"
            when 'ends_with'
              ".*#{@value.downcase}"
            when 'is', '='
              "#{@value.downcase}"
            else
              return
            end
          end
          ["(LOWER(#{@column}) =~ ?)", @value]
        end

        def build_statement_for_enum
          return if @value.blank?
          ["(#{@column} IN (?))", Array.wrap(@value)]
        end
      end
    end
  end
end
