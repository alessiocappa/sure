class Provider::Openai::ChatStreamParser
  Error = Class.new(StandardError)

  def initialize(object)
    @object = object
  end

  def parsed
    chunk = object[:chunk]
    unless chunk.choices.to_a.empty?
      choice = chunk.choices.first
      if choice.delta.content.present?
        Chunk.new(type: "output_text", data: choice.delta.content)
      elsif choice.finish_reason
        Chunk.new(type: "response", data: parse_response(object.snapshot))
      end
    end
  end

  private
    attr_reader :object

    Chunk = Provider::LlmConcept::ChatStreamChunk

    def parse_response(response)
      Provider::Openai::ChatParser.new(response).parsed
    end
end
