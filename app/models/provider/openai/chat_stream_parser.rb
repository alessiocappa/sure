class Provider::Openai::ChatStreamParser
  Error = Class.new(StandardError)

  BUFFER_THRESHOLD = 100

  def initialize(object)
    @object = object
    @buffer = String.new
  end

  def parsed
    chunk = object[:chunk]
    return [] if chunk.choices.to_a.empty?

    case type
    when "response.output_text.delta", "response.refusal.delta"
      Chunk.new(type: "output_text", data: object.dig("delta"), usage: nil)
    when "response.completed"
      raw_response = object.dig("response")
      usage = raw_response.dig("usage")
      Chunk.new(type: "response", data: parse_response(raw_response), usage: usage)
    end

    chunks
  end

  private
    attr_reader :object

    Chunk = Provider::LlmConcept::ChatStreamChunk

    def flush_buffer
      text = @buffer.dup
      @buffer = String.new
      text
    end

    def parse_response(response)
      Provider::Openai::ChatParser.new(response).parsed
    end
end
