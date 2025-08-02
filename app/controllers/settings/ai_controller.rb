class Settings::AiController < ApplicationController
  def show
    @user = Current.user
    @ai_stats = get_ai_stats
    @usage_stats = Current.user.ai_usage_stats
    @usage_warnings = Current.user.ai_usage_warnings
  end

  def update
    @user = Current.user
    
    if @user.update(ai_params)
      redirect_to settings_ai_path, notice: "AI settings updated successfully."
    else
      @ai_stats = get_ai_stats
      render :show, status: :unprocessable_entity
    end
  end

  private

    def ai_params
      params.require(:user).permit(:ai_enabled, :show_ai_sidebar)
    end

    def get_ai_stats
      {
        total_chats: Current.user.chats.count,
        recent_chats: Current.user.chats.where("created_at > ?", 7.days.ago).count,
        error_rate: calculate_error_rate,
        last_used: Current.user.chats.ordered.first&.created_at
      }
    end

    def calculate_error_rate
      recent_chats = Current.user.chats.where("created_at > ?", 7.days.ago)
      return 0 if recent_chats.empty?
      
      error_count = recent_chats.where("error IS NOT NULL").count
      (error_count.to_f / recent_chats.count * 100).round(1)
    end
end 