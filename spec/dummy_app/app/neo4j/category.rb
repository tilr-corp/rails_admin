class Category
  include Neo4j::ActiveNode

  has_one :out, :parent_category, type: :HAS_PARENT, model_class: :Category
end
