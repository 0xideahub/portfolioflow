class TransactionImport < Import
  def import!
    transaction do
      mappings.each(&:create_mappable!)

      transactions = rows.map do |row|
        mapped_account = if account
          account
        else
          mappings.accounts.mappable_for(row.account)
        end

        category = mappings.categories.mappable_for(row.category)
        tags = row.tags_list.map { |tag| mappings.tags.mappable_for(tag) }.compact

        Transaction.new(
          category: category,
          tags: tags,
          entry: Entry.new(
            account: mapped_account,
            date: row.date_iso,
            amount: row.signed_amount,
            name: row.name,
            currency: row.currency,
            notes: row.notes,
            import: self
          )
        )
      end

      Transaction.import!(transactions, recursive: true)
    end
  end

  def required_column_keys
    %i[date amount]
  end

  def column_keys
    base = %i[date amount name currency category tags notes]
    base.unshift(:account) if account.nil?
    base
  end

  def mapping_steps
    base = [ Import::CategoryMapping, Import::TagMapping ]
    base << Import::AccountMapping if account.nil?
    base
  end

  def selectable_amount_type_values
    return [] if entity_type_col_label.nil?

    csv_rows.map { |row| row[entity_type_col_label] }.uniq
  end

  def csv_template
    template = <<-CSV
      date*,amount*,name,currency,category,tags,account,notes
      01/15/2024,-1000.00,401k Contribution,USD,Investment,retirement|401k,401k Account,Monthly 401k contribution
      01/16/2024,2500.00,Dividend Payment,USD,Investment,dividend|income,Brokerage Account,Quarterly dividend from AAPL
      01/17/2024,-500.00,IRA Contribution,USD,Investment,retirement|ira,IRA Account,Monthly IRA contribution
      01/18/2024,-200.00,Investment Purchase,USD,Investment,purchase,Brokerage Account,Additional shares purchase
      01/19/2024,150.00,Interest Payment,USD,Investment,interest|income,Savings Account,Monthly interest payment
    CSV

    csv = CSV.parse(template, headers: true)
    csv.delete("account") if account.present?
    csv
  end
end
