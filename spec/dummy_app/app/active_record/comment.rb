class Comment < ActiveRecord::Base
  include Taggable
  has_one :out, :commentable, type: :COMMENTS_ON, model_class: false
end
