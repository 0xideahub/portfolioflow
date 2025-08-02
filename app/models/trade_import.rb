class TradeImport < Import
  def import!
    transaction do
      mappings.each(&:create_mappable!)

      trades = rows.map do |row|
        mapped_account = if account
          account
        else
          mappings.accounts.mappable_for(row.account)
        end

        # Try to find or create security with ticker only
        security = find_or_create_security(
          ticker: row.ticker,
          exchange_operating_mic: row.exchange_operating_mic
        )

        Trade.new(
          security: security,
          qty: row.qty,
          currency: row.currency.presence || mapped_account.currency,
          price: row.price,
          entry: Entry.new(
            account: mapped_account,
            date: row.date_iso,
            amount: row.signed_amount,
            name: row.name,
            currency: row.currency.presence || mapped_account.currency,
            import: self
          ),
        )
      end

      Trade.import!(trades, recursive: true)
    end
  end

  def mapping_steps
    base = []
    base << Import::AccountMapping if account.nil?
    base
  end

  def required_column_keys
    %i[date ticker qty price]
  end

  def column_keys
    base = %i[date ticker exchange_operating_mic currency qty price name]
    base.unshift(:account) if account.nil?
    base
  end

  def dry_run
    mappings = { transactions: rows.count }

    mappings.merge(
      accounts: Import::AccountMapping.for_import(self).creational.count
    ) if account.nil?

    mappings
  end

  def csv_template
    template = <<-CSV
      date*,ticker*,exchange_operating_mic,currency,qty*,price*,account,name
      01/15/2024,AAPL,XNAS,USD,10,150.00,Brokerage Account,Apple Inc. Purchase
      01/16/2024,GOOGL,XNAS,USD,-5,2500.00,401k Account,Alphabet Inc. Sale
      01/17/2024,TSLA,XNAS,USD,2,700.50,IRA Account,Tesla Inc. Purchase
      01/18/2024,SPY,XNAS,USD,100,450.00,Taxable Account,S&P 500 ETF Buy
      01/19/2024,VTI,XNAS,USD,-25,220.00,Retirement Account,Vanguard Total Market Sale
    CSV

    csv = CSV.parse(template, headers: true)
    csv.delete("account") if account.present?
    csv
  end

  private
    def find_or_create_security(ticker: nil, exchange_operating_mic: nil)
      return nil unless ticker.present?

      # Avoids resolving the same security over and over again (resolver potentially makes network calls)
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
        # Return nil to allow the import to continue with an offline security
        nil
      end
    end

    def validate_investment_data
      rows.each do |row|
        next unless row.ticker.present?
        
        # Validate common investment tickers
        if row.ticker.match?(/\A[A-Z]{1,5}\z/)
          # Valid ticker format
        else
          row.errors.add(:ticker, "Invalid ticker format. Use 1-5 uppercase letters.")
        end
      end
    end
end
