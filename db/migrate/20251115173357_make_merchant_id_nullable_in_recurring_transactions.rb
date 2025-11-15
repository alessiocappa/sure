class MakeMerchantIdNullableInRecurringTransactions < ActiveRecord::Migration[7.2]
  def change
    change_column_null :recurring_transactions, :merchant_id, true
  end
end
