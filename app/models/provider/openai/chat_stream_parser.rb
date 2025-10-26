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

    choice = chunk.choices.first
    chunks = []

    if choice.delta.content.present?
      if @buffer.empty?
        chunks << Chunk.new(type: "output_text", data: choice.delta.content)
      else
        @buffer << choice.delta.content
        if @buffer.length >= BUFFER_THRESHOLD
          chunks << Chunk.new(type: "output_text", data: flush_buffer)
        end
      end
    end

    if choice.finish_reason
      chunks << Chunk.new(type: "output_text", data: flush_buffer) unless @buffer.empty?
      chunks << Chunk.new(type: "response", data: parse_response(object.snapshot))
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
