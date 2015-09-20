class Fan
  include Neo4j::ActiveNode

  property :created_at, type: DateTime
  property :updated_at, type: DateTime

  property :name, type: String

  has_many :in, :teams, type: :HAS_FAN

  validates_presence_of(:name)
end
