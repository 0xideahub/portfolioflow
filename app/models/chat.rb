class Chat < ApplicationRecord
  include Debuggable

  belongs_to :user

  has_one :viewer, class_name: "User", foreign_key: :last_viewed_chat_id, dependent: :nullify # "Last chat user has viewed"
  has_many :messages, dependent: :destroy

  validates :title, presence: true

  scope :ordered, -> { order(created_at: :desc) }

  class << self
    def start!(prompt, model:)
      create!(
        title: generate_title(prompt),
        messages: [ UserMessage.new(content: prompt, ai_model: model) ]
      )
    end

    def generate_title(prompt)
      prompt.first(80)
    end
  end

  def needs_assistant_response?
    conversation_messages.ordered.last.role != "assistant"
  end

  def retry_last_message!
    update!(error: nil)

    last_message = conversation_messages.ordered.last

    if last_message.present? && last_message.role == "user"

      ask_assistant_later(last_message)
    end
  end

  def update_latest_response!(provider_response_id)
    update!(latest_assistant_response_id: provider_response_id)
  end

  def add_error(e)
    error_details = parse_error(e)
    update! error: error_details.to_json
    broadcast_append target: "messages", partial: "chats/error", locals: { chat: self, error_details: error_details }
  end

  def clear_error
    update! error: nil
    broadcast_remove target: "chat-error"
  end

  def assistant
    @assistant ||= Assistant.for_chat(self)
  end

  def ask_assistant_later(message)
    clear_error
    AssistantResponseJob.perform_later(message)
  end

  def ask_assistant(message)
    assistant.respond_to(message)
  end

  def conversation_messages
    if debug_mode?
      messages
    else
      messages.where(type: [ "UserMessage", "AssistantMessage" ])
    end
  end

  def error_details
    return nil unless error.present?

    if error.is_a?(String)
      begin
        parsed = JSON.parse(error)
        Rails.logger.debug "Parsed error details: #{parsed.inspect}"
        # Ensure we return a hash with symbol keys
        parsed.is_a?(Hash) ? parsed.symbolize_keys : fallback_error_details
      rescue JSON::ParserError => e
        Rails.logger.debug "Failed to parse error JSON: #{error}, error: #{e.message}"
        fallback_error_details
      end
    elsif error.is_a?(Hash)
      Rails.logger.debug "Error is already a hash: #{error.inspect}"
      error.symbolize_keys
    else
      Rails.logger.debug "Error is not a string or hash: #{error.class}, value: #{error.inspect}"
      fallback_error_details
    end
  end

  private

    def fallback_error_details
      {
        type: "unknown_error",
        title: "Something Went Wrong",
        message: "We encountered an unexpected error. Please try again.",
        action: "retry"
      }
    end

    def parse_error(error)
      case error
      when Provider::Openai::Error
        case error.message
        when /rate limit/i
          {
            type: "rate_limit",
            title: "AI Service Temporarily Unavailable",
            message: "We're experiencing high demand. Please try again in a few minutes.",
            action: "retry_later",
            retry_after: 60
          }
        when /quota exceeded/i
          {
            type: "quota_exceeded",
            title: "AI Usage Limit Reached",
            message: "You've reached your AI usage limit for this period. Please try again later or contact support.",
            action: "contact_support"
          }
        when /invalid api key/i
          {
            type: "invalid_api_key",
            title: "AI Configuration Issue",
            message: "AI service is not properly configured. Please contact your administrator.",
            action: "contact_admin"
          }
        else
          {
            type: "openai_error",
            title: "AI Service Error",
            message: "We're having trouble connecting to our AI service. Please try again.",
            action: "retry"
          }
        end
      when Provider::Error
        {
          type: "provider_error",
          title: "AI Service Unavailable",
          message: "AI features are currently unavailable. Please try again later.",
          action: "retry"
        }
      else
        {
          type: "unknown_error",
          title: "Something Went Wrong",
          message: "We encountered an unexpected error. Please try again.",
          action: "retry"
        }
      end
    end
end
