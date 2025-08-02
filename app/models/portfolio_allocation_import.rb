class PortfolioAllocationImport < Import
  def import!
    transaction do
      mappings.each(&:create_mappable!)

      # Create valuation entries for current portfolio holdings
      valuations = rows.map do |row|
        mapped_account = if account
          account
        else
          mappings.accounts.mappable_for(row.account)
        end

        # Create a valuation entry for the current portfolio value
        Valuation.new(
          entry: Entry.new(
            account: mapped_account,
            date: row.date_iso,
            amount: row.portfolio_value,
            currency: row.currency,
            name: "Portfolio Valuation",
            notes: "Imported portfolio allocation",
            import: self
          )
        )
      end

      # Create holdings for each security
      holdings = rows.flat_map do |row|
        next [] unless row.ticker.present?
        
        mapped_account = if account
          account
        else
          mappings.accounts.mappable_for(row.account)
        end

        security = find_or_create_security(
          ticker: row.ticker,
          exchange_operating_mic: row.exchange_operating_mic
        )

        next [] unless security

        Holding.new(
          account: mapped_account,
          security: security,
          date: row.date_iso,
          qty: row.qty,
          price: row.price,
          currency: row.currency.presence || mapped_account.currency
        )
      end

      Valuation.import!(valuations, recursive: true)
      Holding.import!(holdings, recursive: true)
    end
  end

  def mapping_steps
    base = []
    base << Import::AccountMapping if account.nil?
    base
  end

  def required_column_keys
    %i[date portfolio_value]
  end

  def column_keys
    base = %i[date portfolio_value currency ticker exchange_operating_mic qty price]
    base.unshift(:account) if account.nil?
    base
  end

  def dry_run
    mappings = { 
      valuations: rows.count,
      holdings: rows.select { |row| row.ticker.present? }.count
    }

    mappings.merge(
      accounts: Import::AccountMapping.for_import(self).creational.count
    ) if account.nil?

    mappings
  end

  def csv_template
    template = <<-CSV
      date*,portfolio_value*,currency,ticker,exchange_operating_mic,qty,price,account
      01/15/2024,50000.00,USD,AAPL,XNAS,100,150.00,Brokerage Account
      01/15/2024,50000.00,USD,GOOGL,XNAS,20,2500.00,401k Account
      01/15/2024,50000.00,USD,SPY,XNAS,200,450.00,Taxable Account
      01/15/2024,50000.00,USD,VTI,XNAS,500,220.00,IRA Account
      01/15/2024,50000.00,USD,TSLA,XNAS,50,700.00,Retirement Account
    CSV

    csv = CSV.parse(template, headers: true)
    csv.delete("account") if account.present?
    csv
  end

  private
    def find_or_create_security(ticker: nil, exchange_operating_mic: nil)
      return nil unless ticker.present?

      # Avoids resolving the same security over and over again
      @security_cache ||= {}

      cache_key = [ ticker, exchange_operating_mic ].compact.join(":")

      security = @security_cache[cache_key]

      return security if security.present?

      begin
        security = Security::Resolver.new(
          ticker,
          exchange_operating_mic: exchange_operating_mic.presence
        ).resolve

        @security_cache[cache_key] = security

        security
      rescue => e
        Rails.logger.error "Failed to resolve security #{ticker}: #{e.message}"
        nil
      end
    end
end 