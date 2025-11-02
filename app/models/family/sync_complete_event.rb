class Family::SyncCompleteEvent
  attr_reader :family

  def initialize(family)
    @family = family
  end

  def broadcast
    family.broadcast_replace(
      target: "balance-sheet",
      partial: "pages/dashboard/balance_sheet",
      locals: { balance_sheet: family.balance_sheet }
    )

    begin
      family.broadcast_replace(
        target: "net-worth-chart",
        partial: "pages/dashboard/net_worth_chart",
        locals: { balance_sheet: family.balance_sheet, period: Period.last_30_days }
      )
    rescue => e
      Rails.logger.error("Family::SyncCompleteEvent net_worth_chart broadcast failed: #{e.message}\n#{e.backtrace&.join("\n")}")
    end

    # Identify recurring transaction patterns after sync
    begin
      RecurringTransaction.identify_patterns_for(family)
    rescue => e
      Rails.logger.error("Family::SyncCompleteEvent recurring transaction identification failed: #{e.message}\n#{e.backtrace&.join("\n")}")
    end
  end
end
