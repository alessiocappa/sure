class AddIdentificationHashToEnableBankingAccounts < ActiveRecord::Migration[7.2]
  def change
    add_column :enable_banking_accounts, :identification_hash, :string
  end
end
