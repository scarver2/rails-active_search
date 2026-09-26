require "test_helper"

class SqlserverTest < ActiveSupport::TestCase
  setup do
    skip "SQL Server tests require SEARCH_ADAPTER=sqlserver" unless store_adapter_name == :sqlserver
  end

  test "sanitizes terms into literal CONTAINS expressions" do
    store = ActiveSearch::StoreAdapters::Sqlserver.new

    assert_equal '"ruby" AND "guide"', store.send(:sanitize_contains_query, "ruby guide")
    assert_equal '"ruby guide" AND "today"', store.send(:sanitize_contains_query, '"ruby guide" today')
    assert_equal '"alpha" AND "beta"', store.send(:sanitize_contains_query, "+alpha -beta")
  end
end
