class Provider::Openai::ChatParser
  Error = Class.new(StandardError)

  def initialize(object)
    @object = object
  end

  def parsed
    ChatResponse.new(
      id: response_id,
      model: response_model,
      messages: messages,
      function_requests: function_requests
    )
  end

  private
    attr_reader :object

    ChatResponse = Provider::LlmConcept::ChatResponse
    ChatMessage = Provider::LlmConcept::ChatMessage
    ChatFunctionRequest = Provider::LlmConcept::ChatFunctionRequest

    def response_id
      object[:id]
    end

    def response_model
      object[:model]
    end

    def choices
      choices = object[:choices]
      choices.is_a?(Array) ? choices : []
    end

    def messages
      choices.map do |choice|
        message = choice[:message]
        text = message[:content]
        refusal = message[:refusal]

        ChatMessage.new(
          id: response_id,
          output_text: text || refusal
        )
      end
    end

    def function_requests
      return [] if choices.empty?

      choice = choices.first
      message = choice[:message]
      tool_calls = message[:tool_calls] || []

      tool_calls.map do |tool_call|
        function = tool_call[:function]
        next unless function

        ChatFunctionRequest.new(
          id: tool_call[:id],
          call_id: tool_call[:id],
          function_name: function[:name],
          function_args: function[:arguments]
        )
      end.compact
    end
end
