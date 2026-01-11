class SimplefinItem < ApplicationRecord
  include Syncable, Provided
  include SimplefinItem::Unlinking

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  # Virtual attribute for the setup token form field
  attr_accessor :setup_token

  # Helper to detect if ActiveRecord Encryption is configured for this app
  def self.encryption_ready?
    creds_ready = Rails.application.credentials.active_record_encryption.present?
    env_ready = ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"].present? &&
                ENV["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"].present? &&
                ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"].present?
    creds_ready || env_ready
  end

  # Encrypt sensitive credentials if ActiveRecord encryption is configured (credentials OR env vars)
  if encryption_ready?
    encrypts :access_url, deterministic: true
  end

  validates :name, presence: true
  validates :access_url, presence: true, on: :create

  before_destroy :remove_simplefin_item

  belongs_to :family
  has_one_attached :logo

  has_many :simplefin_accounts, dependent: :destroy
  has_many :legacy_accounts, through: :simplefin_accounts, source: :account

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  # Get accounts from both new and legacy systems
  def accounts
    # Preload associations to avoid N+1 queries
    simplefin_accounts
      .includes(:account, account_provider: :account)
      .map(&:current_account)
      .compact
      .uniq
  end

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  def import_latest_simplefin_data(sync: nil)
    SimplefinItem::Importer.new(self, simplefin_provider: simplefin_provider, sync: sync).import
  end

  def process_accounts
    simplefin_accounts.joins(:account).each do |simplefin_account|
      SimplefinAccount::Processor.new(simplefin_account).process
    end
  end

  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    accounts.each do |account|
      account.sync_later(
        parent_sync: parent_sync,
        window_start_date: window_start_date,
        window_end_date: window_end_date
      )
    end
  end

  def upsert_simplefin_snapshot!(accounts_snapshot)
    assign_attributes(
      raw_payload: accounts_snapshot,
    )

    # Do not populate item-level institution fields from account data.
    # Institution metadata belongs to each simplefin_account (in org_data).

    save!
  end

  def upsert_institution_data!(org_data)
    org = org_data.to_h.with_indifferent_access
    url = org[:url] || org[:"sfin-url"]
    domain = org[:domain]

    # Derive domain from URL if missing
    if domain.blank? && url.present?
      begin
        domain = URI.parse(url).host&.gsub(/^www\./, "")
      rescue URI::InvalidURIError
        Rails.logger.warn("Invalid SimpleFin institution URL: #{url.inspect}")
      end
    end

    assign_attributes(
      institution_id: org[:id],
      institution_name: org[:name],
      institution_domain: domain,
      institution_url: url,
      raw_institution_payload: org_data
    )
  end


  def has_completed_initial_setup?
    # Setup is complete if we have any linked accounts
    accounts.any?
  end

  def sync_status_summary
    latest = latest_sync
    return nil unless latest

    # If sync has statistics, use them
    stats = parse_sync_stats(latest.sync_stats)
    if stats.present?
      total = stats["total_accounts"] || 0
      linked = stats["linked_accounts"] || 0
      unlinked = stats["unlinked_accounts"] || 0

      if total == 0
        "No accounts found"
      elsif unlinked == 0
        "#{linked} #{'account'.pluralize(linked)} synced"
      else
        "#{linked} synced, #{unlinked} need setup"
      end
    else
      # Fallback to current account counts
      total_accounts = simplefin_accounts.count
      linked_count = accounts.count
      unlinked_count = total_accounts - linked_count

      if total_accounts == 0
        "No accounts found"
      elsif unlinked_count == 0
        "#{linked_count} #{'account'.pluralize(linked_count)} synced"
      else
        "#{linked_count} synced, #{unlinked_count} need setup"
      end
    end
  end

  def institution_display_name
    # Try to get institution name from stored metadata
    institution_name.presence || institution_domain.presence || name
  end

  def connected_institutions
    # Get unique institutions from all accounts
    simplefin_accounts.includes(:account)
                     .where.not(org_data: nil)
                     .map { |acc| acc.org_data }
                     .uniq { |org| org["domain"] || org["name"] }
  end

  def institution_summary
    institutions = connected_institutions
    case institutions.count
    when 0
      "No institutions connected"
    when 1
      institutions.first["name"] || institutions.first["domain"] || "1 institution"
    else
      "#{institutions.count} institutions"
    end
  end



  # Detect a recent rate-limited sync and return a friendly message, else nil
  def rate_limited_message
    latest = latest_sync
    return nil unless latest

    # Some Sync records may not have a status_text column; guard with respond_to?
    parts = []
    parts << latest.error if latest.respond_to?(:error)
    parts << latest.status_text if latest.respond_to?(:status_text)
    msg = parts.compact.join(" — ")
    return nil if msg.blank?

    down = msg.downcase
    if down.include?("make fewer requests") || down.include?("only refreshed once every 24 hours") || down.include?("rate limit")
      "You've hit SimpleFin's daily refresh limit. Please try again after the bridge refreshes (up to 24 hours)."
    else
      nil
    end
  end

  # Detect if sync data appears stale (no new transactions for extended period)
  # Returns a hash with :stale (boolean) and :message (string) if stale
  def stale_sync_status
    return { stale: false } unless last_synced_at.present?

    # Check if last sync was more than 3 days ago
    days_since_sync = (Date.current - last_synced_at.to_date).to_i
    if days_since_sync > 3
      return {
        stale: true,
        days_since_sync: days_since_sync,
        message: "Last successful sync was #{days_since_sync} days ago. Your SimpleFin connection may need attention."
      }
    end

    # Check if linked accounts have recent transactions
    linked_accounts = accounts
    return { stale: false } if linked_accounts.empty?

    # Find the most recent transaction date across all linked accounts
    latest_transaction_date = Entry.where(account_id: linked_accounts.map(&:id))
                                   .where(entryable_type: "Transaction")
                                   .maximum(:date)

    if latest_transaction_date.present?
      days_since_transaction = (Date.current - latest_transaction_date).to_i
      if days_since_transaction > 14
        return {
          stale: true,
          days_since_transaction: days_since_transaction,
          message: "No new transactions in #{days_since_transaction} days. Check your SimpleFin dashboard to ensure your bank connections are active."
        }
      end
    end

    { stale: false }
  end

  # Check if the SimpleFin connection needs user attention
  def needs_attention?
    requires_update? || stale_sync_status[:stale] || pending_account_setup?
  end

  # Get a summary of issues requiring attention
  def attention_summary
    issues = []
    issues << "Connection needs update" if requires_update?
    issues << stale_sync_status[:message] if stale_sync_status[:stale]
    issues << "Accounts need setup" if pending_account_setup?
    issues
  end

  # Get reconciled duplicates count from the last sync
  # Returns { count: N, message: "..." } or { count: 0 } if none
  def last_sync_reconciled_status
    latest_sync = syncs.ordered.first
    return { count: 0 } unless latest_sync

    stats = parse_sync_stats(latest_sync.sync_stats)
    count = stats&.dig("pending_reconciled").to_i
    if count > 0
      {
        count: count,
        message: I18n.t("simplefin_items.reconciled_status.message", count: count)
      }
    else
      { count: 0 }
    end
  end

  # Count stale pending transactions (>8 days old) across all linked accounts
  # Returns { count: N, accounts: [names] } or { count: 0 } if none
  def stale_pending_status(days: 8)
    # Get all accounts linked to this SimpleFIN item
    # Eager-load both association paths to avoid N+1 on current_account method
    linked_accounts = simplefin_accounts.includes(:account, :linked_account).filter_map(&:current_account)
    return { count: 0 } if linked_accounts.empty?

    # Batch query to avoid N+1
    account_ids = linked_accounts.map(&:id)
    counts_by_account = Entry.stale_pending(days: days)
      .where(excluded: false)
      .where(account_id: account_ids)
      .group(:account_id)
      .count

    account_counts = linked_accounts
      .map { |account| { account: account, count: counts_by_account[account.id].to_i } }
      .select { |ac| ac[:count] > 0 }

    total = account_counts.sum { |ac| ac[:count] }
    if total > 0
      {
        count: total,
        accounts: account_counts.map { |ac| ac[:account].name },
        message: I18n.t("simplefin_items.stale_pending_status.message", count: total, days: days)
      }
    else
      { count: 0 }
    end
  end

  private
    # Parse sync_stats, handling cases where it might be a raw JSON string
    # (e.g., from console testing or bypassed serialization)
    def parse_sync_stats(sync_stats)
      return nil if sync_stats.blank?
      return sync_stats if sync_stats.is_a?(Hash)

      if sync_stats.is_a?(String)
        JSON.parse(sync_stats) rescue nil
      end
    end

    def remove_simplefin_item
      # SimpleFin doesn't require server-side cleanup like Plaid
      # The access URL just becomes inactive
    end
end
