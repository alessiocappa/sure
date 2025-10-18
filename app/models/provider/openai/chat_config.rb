class Provider::Openai::ChatConfig
  def initialize(functions: [], function_results: [])
    @functions = functions
    @function_results = function_results
  end

  def tools
    functions.map do |fn|
      {
        type: "function",
        function: {
          name: fn[:name],
          description: fn[:description],
          parameters: fn[:params_schema],
          strict: fn[:strict]
        }
      }
    end
  end

  def build_input(prompt, previous_messages: [])
    new_user_message = { role: "user", content: prompt }

    tool_result_messages = function_results.map do |fn_result|
      {
        role: "tool",
        tool_call_id: fn_result[:call_id],
        content: fn_result[:output].to_json
      }
    end

    [
      *previous_messages,
      new_user_message,
      *tool_result_messages
    ]
end

  private
    attr_reader :functions, :function_results
end
