class Provider::Openai < Provider
  include LlmConcept

  # Subclass so errors caught in this provider are raised as Provider::Openai::Error
  Error = Class.new(Provider::Error)

  DEFAULT_MODEL = "gpt-4.1"

  def initialize(access_token, base_url = nil, model)
    @model = model.presence || DEFAULT_MODEL

    params = {
      api_key: access_token,
      base_url: base_url
    }.compact

    @client = ::OpenAI::Client.new(**params)
  end

  def supports_model?(model)
    MODELS.include?(model)
  end

  def auto_categorize(transactions: [], user_categories: [], model: "")
    with_provider_response do
      raise Error, "Too many transactions to auto-categorize. Max is 25 per request." if transactions.size > 25

      result = AutoCategorizer.new(
        client,
        model: @model, # Ignore model coming from function parameters for now
        transactions: transactions,
        user_categories: user_categories
      ).auto_categorize

      log_langfuse_generation(
        name: "auto_categorize",
        model: model,
        input: { transactions: transactions, user_categories: user_categories },
        output: result.map(&:to_h)
      )

      result
    end
  end

  def auto_detect_merchants(transactions: [], user_merchants: [], model: "")
    with_provider_response do
      raise Error, "Too many transactions to auto-detect merchants. Max is 25 per request." if transactions.size > 25

      result = AutoMerchantDetector.new(
        client,
        model: @model, # Ignore model coming from function parameters for now
        transactions: transactions,
        user_merchants: user_merchants
      ).auto_detect_merchants

      log_langfuse_generation(
        name: "auto_detect_merchants",
        model: model,
        input: { transactions: transactions, user_merchants: user_merchants },
        output: result.map(&:to_h)
      )

      result
    end
  end

  def chat_response(
    prompt,
    model:,
    instructions: nil,
    functions: [],
    function_results: [],
    streamer: nil,
    previous_response_id: nil,
    session_id: nil,
    user_identifier: nil
  )
    with_provider_response do
      chat_config = ChatConfig.new(
        functions: functions,
        function_results: function_results
      )

      collected_chunks = []

      # Proxy that converts raw stream to "LLM Provider concept" stream
      stream_proxy = if streamer.present?
        proc do |chunk|
          parsed_chunk = ChatStreamParser.new(chunk).parsed

          unless parsed_chunk.nil?
            streamer.call(parsed_chunk)
            collected_chunks << parsed_chunk
          end
        end
      else
        nil
      end

      params = {
        model: @model, # Ignore model coming from function parameters for now
        messages: chat_config.build_input(prompt),
        instructions: instructions,
        tools: chat_config.tools,
        previous_response_id: previous_response_id
      }.compact

      if streamer.present?
        # Proxy that converts raw stream to "LLM Provider concept" stream
        stream_proxy = client.chat.completions.stream(**params)
        stream_proxy.each do |event|
          case event
          when OpenAI::Streaming::ChatChunkEvent
            parsed_chunk = ChatStreamParser.new(event).parsed

            unless parsed_chunk.nil?
              streamer.call(parsed_chunk)
              collected_chunks << parsed_chunk
            end
          end
        end
      else
        raw_response = client.chat.completions.create(**params)
        ChatParser.new(raw_response).parsed
      end
    end
  end

  private
    attr_reader :client

    def langfuse_client
      return unless ENV["LANGFUSE_PUBLIC_KEY"].present? && ENV["LANGFUSE_SECRET_KEY"].present?

      @langfuse_client = Langfuse.new
    end

    def log_langfuse_generation(name:, model:, input:, output:, usage: nil, session_id: nil, user_identifier: nil)
      return unless langfuse_client

      trace = langfuse_client.trace(
        name: "openai.#{name}",
        input: input,
        session_id: session_id,
        user_id: user_identifier
      )
      trace.generation(
        name: name,
        model: model,
        input: input,
        output: output,
        usage: usage,
        session_id: session_id,
        user_id: user_identifier
      )
      trace.update(output: output)
    rescue => e
      Rails.logger.warn("Langfuse logging failed: #{e.message}")
    end
end
