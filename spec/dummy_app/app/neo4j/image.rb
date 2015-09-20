class Image
  include Neo4j::ActiveNode
  include Neo4jrb::Paperclip

  has_neo4jrb_attached_file :file, styles: {medium: '300x300>', thumb: '100x100>'}
  validates_attachment_presence :file
end
