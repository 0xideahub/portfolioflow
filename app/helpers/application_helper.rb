module ApplicationHelper
  include Pagy::Frontend

  def styled_form_with(**options, &block)
    options[:builder] = StyledFormBuilder
    form_with(**options, &block)
  end

  def icon(key, size: "md", color: "default", custom: false, as_button: false, **opts)
    extra_classes = opts.delete(:class)
    sizes = { xs: "w-3 h-3", sm: "w-4 h-4", md: "w-5 h-5", lg: "w-6 h-6", xl: "w-7 h-7", "2xl": "w-8 h-8" }
    colors = { default: "fg-gray", white: "fg-inverse", success: "text-success", warning: "text-warning", destructive: "text-destructive", current: "text-current" }

    icon_classes = class_names(
      "shrink-0",
      sizes[size.to_sym],
      colors[color.to_sym],
      extra_classes
    )

    if custom
      inline_svg_tag("#{key}.svg", class: icon_classes, **opts)
    elsif as_button
      render DS::Button.new(variant: "icon", class: extra_classes, icon: key, size: size, type: "button", **opts)
    else
      lucide_icon(key, class: icon_classes, **opts)
    end
  end

  # Convert alpha (0-1) to 8-digit hex (00-FF)
  def hex_with_alpha(hex, alpha)
    alpha_hex = (alpha * 255).round.to_s(16).rjust(2, "0")
    "#{hex}#{alpha_hex}"
  end

  def title(page_title)
    content_for(:title) { page_title }
  end

  def header_title(page_title)
    content_for(:header_title) { page_title }
  end

  def header_description(page_description)
    content_for(:header_description) { page_description }
  end

  def page_active?(path)
    current_page?(path) || (request.path.start_with?(path) && path != "/")
  end

  # Wrapper around I18n.l to support custom date formats
  def format_date(object, format = :default, options = {})
    date = object.to_date

    format_code = options[:format_code] || Current.family&.date_format

    if format_code.present?
      date.strftime(format_code)
    else
      I18n.l(date, format: format, **options)
    end
  end

  def format_money(number_or_money, options = {})
    return nil unless number_or_money

    Money.new(number_or_money).format(options)
  end

  def totals_by_currency(collection:, money_method:, separator: " | ", negate: false)
    collection.group_by(&:currency)
              .transform_values { |item| calculate_total(item, money_method, negate) }
              .map { |_currency, money| format_money(money) }
              .join(separator)
  end

  def show_super_admin_bar?
    if params[:admin].present?
      cookies.permanent[:admin] = params[:admin]
    end

    cookies[:admin] == "true"
  end

  # Renders Markdown text using Redcarpet with sanitization
  def markdown(text)
    return "" if text.blank?

    renderer = Redcarpet::Render::HTML.new(
      hard_wrap: true,
      link_attributes: { target: "_blank", rel: "noopener noreferrer" }
    )

    markdown = Redcarpet::Markdown.new(
      renderer,
      autolink: true,
      tables: true,
      fenced_code_blocks: true,
      strikethrough: true,
      superscript: true,
      underline: true,
      highlight: true,
      quote: true,
      footnotes: true
    )

    # Sanitize the rendered HTML to prevent XSS
    sanitize(markdown.render(text), tags: %w[p br strong em b i u h1 h2 h3 h4 h5 h6 ul ol li blockquote code pre a], attributes: %w[href target rel])
  end

  def ai_status_for_user(user)
    return :unavailable unless user.ai_available?
    return :disabled unless user.ai_enabled?
    :available
  end

  def ai_status_message(user)
    case ai_status_for_user(user)
    when :available
      "AI Assistant is ready to help"
    when :disabled
      "AI Assistant is disabled. Enable it in settings to get started."
    when :unavailable
      if Rails.application.config.app_mode.self_hosted?
        "AI Assistant requires OpenAI API key configuration"
      else
        "AI Assistant is temporarily unavailable"
      end
    end
  end

  def ai_status_icon(user)
    case ai_status_for_user(user)
    when :available
      "check-circle"
    when :disabled
      "x-circle"
    when :unavailable
      "alert-circle"
    end
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

  def ai_availability_notification
    return nil unless Current.user.present?
    
    case ai_status_for_user(Current.user)
    when :available
      nil # No notification needed when available
    when :disabled
      {
        type: "info",
        title: "AI Assistant Available",
        message: "AI features are ready to use. Enable them in settings to get started.",
        action: "Enable AI",
        action_path: settings_ai_path
      }
    when :unavailable
      if Rails.application.config.app_mode.self_hosted?
        {
          type: "warning",
          title: "AI Setup Required",
          message: "Configure your OpenAI API key to enable AI features.",
          action: "Setup AI",
          action_path: settings_ai_path
        }
      else
        {
          type: "warning",
          title: "AI Temporarily Unavailable",
          message: "AI features are currently unavailable. Please try again later.",
          action: "Check Status",
          action_path: settings_ai_path
        }
      end
    end
  end

  private
    def calculate_total(item, money_method, negate)
      # Filter out transfer-type transactions from entries
      # Only Entry objects have entryable transactions, Account objects don't
      items = item.reject do |i|
        i.is_a?(Entry) &&
        i.entryable.is_a?(Transaction) &&
        i.entryable.transfer?
      end
      total = items.sum(&money_method)
      negate ? -total : total
    end
end
