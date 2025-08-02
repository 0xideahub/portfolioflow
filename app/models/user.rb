class User < ApplicationRecord
  has_secure_password

  belongs_to :family
  belongs_to :last_viewed_chat, class_name: "Chat", optional: true
  has_many :sessions, dependent: :destroy
  has_many :chats, dependent: :destroy
  has_many :api_keys, dependent: :destroy
  has_many :mobile_devices, dependent: :destroy
  has_many :invitations, foreign_key: :inviter_id, dependent: :destroy
  has_many :impersonator_support_sessions, class_name: "ImpersonationSession", foreign_key: :impersonator_id, dependent: :destroy
  has_many :impersonated_support_sessions, class_name: "ImpersonationSession", foreign_key: :impersonated_id, dependent: :destroy
  accepts_nested_attributes_for :family, update_only: true

  validates :email, presence: true, uniqueness: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validate :ensure_valid_profile_image
  validates :default_period, inclusion: { in: Period::PERIODS.keys }
  normalizes :email, with: ->(email) { email.strip.downcase }
  normalizes :unconfirmed_email, with: ->(email) { email&.strip&.downcase }

  normalizes :first_name, :last_name, with: ->(value) { value.strip.presence }

  enum :role, { member: "member", admin: "admin", super_admin: "super_admin" }, validate: true

  has_one_attached :profile_image do |attachable|
    attachable.variant :thumbnail, resize_to_fill: [ 300, 300 ], convert: :webp, saver: { quality: 80 }
    attachable.variant :small, resize_to_fill: [ 72, 72 ], convert: :webp, saver: { quality: 80 }, preprocessed: true
  end

  validate :profile_image_size

  generates_token_for :password_reset, expires_in: 15.minutes do
    password_salt&.last(10)
  end

  generates_token_for :email_confirmation, expires_in: 1.day do
    unconfirmed_email
  end

  def pending_email_change?
    unconfirmed_email.present?
  end

  def initiate_email_change(new_email)
    return false if new_email == email
    return false if new_email == unconfirmed_email

    if Rails.application.config.app_mode.self_hosted? && !Setting.require_email_confirmation
      update(email: new_email)
    else
      if update(unconfirmed_email: new_email)
        EmailConfirmationMailer.with(user: self).confirmation_email.deliver_later
        true
      else
        false
      end
    end
  end

  def request_impersonation_for(user_id)
    impersonated = User.find(user_id)
    impersonator_support_sessions.create!(impersonated: impersonated)
  end

  def admin?
    super_admin? || role == "admin"
  end

  def display_name
    [ first_name, last_name ].compact.join(" ").presence || email
  end

  def initial
    (display_name&.first || email.first).upcase
  end

  def initials
    if first_name.present? && last_name.present?
      "#{first_name.first}#{last_name.first}".upcase
    else
      initial
    end
  end

  def show_ai_sidebar?
    show_ai_sidebar
  end

  def ai_available?
    !Rails.application.config.app_mode.self_hosted? || ENV["OPENAI_ACCESS_TOKEN"].present?
  end

  def ai_enabled?
    ai_enabled && ai_available?
  end

  def ai_status_color(user)
    case ai_status_for_user(user)
    when :available
      "text-green-600"
    when :disabled
      "text-yellow-600"
    when :unavailable
      "text-red-600"
    end
  end

  # AI Usage Tracking
  def ai_usage_stats(days: 30)
    end_date = Date.current
    start_date = end_date - days.days
    
    recent_chats = chats.where(created_at: start_date..end_date)
    total_messages = recent_chats.joins(:messages).count
    
    {
      total_chats: recent_chats.count,
      total_messages: total_messages,
      avg_messages_per_chat: recent_chats.any? ? (total_messages.to_f / recent_chats.count).round(1) : 0,
      error_rate: calculate_ai_error_rate(recent_chats),
      estimated_cost: estimate_ai_cost(total_messages),
      usage_trend: calculate_usage_trend(days)
    }
  end

  def ai_usage_warnings
    warnings = []
    
    # Check for high error rates
    recent_stats = ai_usage_stats(days: 7)
    if recent_stats[:error_rate] > 20
      warnings << {
        type: "high_error_rate",
        message: "High error rate detected. Consider checking your AI configuration.",
        severity: "warning"
      }
    end
    
    # Check for high usage
    if recent_stats[:total_messages] > 100
      warnings << {
        type: "high_usage",
        message: "High AI usage detected. Monitor your API costs.",
        severity: "info"
      }
    end
    
    warnings
  end

  # Deactivation
  validate :can_deactivate, if: -> { active_changed? && !active }
  after_update_commit :purge_later, if: -> { saved_change_to_active?(from: true, to: false) }

  def deactivate
    update active: false, email: deactivated_email
  end

  def can_deactivate
    if admin? && family.users.count > 1
      errors.add(:base, :cannot_deactivate_admin_with_other_users)
    end
  end

  def purge_later
    UserPurgeJob.perform_later(self)
  end

  def purge
    if last_user_in_family?
      family.destroy
    else
      destroy
    end
  end

  # MFA
  def setup_mfa!
    update!(
      otp_secret: ROTP::Base32.random(32),
      otp_required: false,
      otp_backup_codes: []
    )
  end

  def enable_mfa!
    update!(
      otp_required: true,
      otp_backup_codes: generate_backup_codes
    )
  end

  def disable_mfa!
    update!(
      otp_secret: nil,
      otp_required: false,
      otp_backup_codes: []
    )
  end

  def verify_otp?(code)
    return false if otp_secret.blank?
    return true if verify_backup_code?(code)
    totp.verify(code, drift_behind: 15)
  end

  def provisioning_uri
    return nil unless otp_secret.present?
    totp.provisioning_uri(email)
  end

  def onboarded?
    onboarded_at.present?
  end

  def needs_onboarding?
    !onboarded?
  end

  private
    def ensure_valid_profile_image
      return unless profile_image.attached?

      unless profile_image.content_type.in?(%w[image/jpeg image/png])
        errors.add(:profile_image, "must be a JPEG or PNG")
        profile_image.purge
      end
    end

    def last_user_in_family?
      family.users.count == 1
    end

    def deactivated_email
      email.gsub(/@/, "-deactivated-#{SecureRandom.uuid}@")
    end

    def profile_image_size
      if profile_image.attached? && profile_image.byte_size > 10.megabytes
        errors.add(:profile_image, :invalid_file_size, max_megabytes: 10)
      end
    end

    def totp
      ROTP::TOTP.new(otp_secret, issuer: "Maybe Finance")
    end

    def verify_backup_code?(code)
      return false if otp_backup_codes.blank?

      # Find and remove the used backup code
      if (index = otp_backup_codes.index(code))
        remaining_codes = otp_backup_codes.dup
        remaining_codes.delete_at(index)
        update_column(:otp_backup_codes, remaining_codes)
        true
      else
        false
      end
    end

    def generate_backup_codes
      8.times.map { SecureRandom.hex(4) }
    end

    def calculate_ai_error_rate(chats)
      return 0 if chats.empty?
      
      error_count = chats.where("error IS NOT NULL").count
      (error_count.to_f / chats.count * 100).round(1)
    end

    def estimate_ai_cost(message_count)
      # Rough estimate: $0.03 per 1K tokens, ~100 tokens per message
      estimated_tokens = message_count * 100
      estimated_cost = (estimated_tokens / 1000.0) * 0.03
      estimated_cost.round(2)
    end

    def calculate_usage_trend(days)
      return [] if days < 7
      
      (0..6).map do |i|
        date = Date.current - i.days
        count = chats.where(created_at: date.beginning_of_day..date.end_of_day).count
        { date: date, count: count }
      end.reverse
    end
end
