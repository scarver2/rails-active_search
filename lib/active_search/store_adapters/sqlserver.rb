module ActiveSearch
  module StoreAdapters
    # Store adapter for Microsoft SQL Server Full-Text Search, selected with
    # <tt>adapter: sqlserver</tt>.
    #
    # Searches the application database through Active Record. SQL Server requires one unique,
    # non-null key index for each full-text index; generated migrations create a dedicated index on
    # the document table's primary key and use CONTAINSTABLE to return native relevance ranks.
    class Sqlserver < Database
      extend ActiveSupport::Autoload

      eager_autoload do
        autoload :QueryBuilding
      end

      include QueryBuilding

      CATALOG_NAME = "active_search".freeze

      def migration_preamble_lines
        [ "  disable_ddl_transaction!", "" ]
      end

      def search_index_lines(table_name, text_names)
        key_index = fulltext_key_index_name(table_name)
        columns = text_names.map { |name| "[#{name}] LANGUAGE 1033" }.join(", ")

        [
          "",
          "    add_index :#{table_name}, :id, unique: true, name: :#{key_index}",
          "",
          "    reversible do |direction|",
          "      direction.up do",
          "        execute \"IF FULLTEXTSERVICEPROPERTY('IsFullTextInstalled') <> 1 THROW 50000, 'SQL Server Full-Text Search is not installed', 1\"",
          "        execute \"IF NOT EXISTS (SELECT 1 FROM sys.fulltext_catalogs WHERE name = '#{CATALOG_NAME}') CREATE FULLTEXT CATALOG [#{CATALOG_NAME}]\"",
          "        execute \"CREATE FULLTEXT INDEX ON [#{table_name}] (#{columns}) KEY INDEX [#{key_index}] ON [#{CATALOG_NAME}] WITH CHANGE_TRACKING MANUAL\"",
          "      end",
          "    end"
        ]
      end

      def search_native_type
        "fulltext"
      end

      def observe_tables(index, table, connection)
        searchable = connection.select_values(<<~SQL.squish)
          SELECT columns.name
          FROM sys.fulltext_index_columns AS fulltext_columns
          INNER JOIN sys.columns AS columns
            ON columns.object_id = fulltext_columns.object_id
           AND columns.column_id = fulltext_columns.column_id
          WHERE fulltext_columns.object_id = OBJECT_ID(#{connection.quote(table)})
        SQL

        columns_in(connection, table, role: :filterable) + searchable.map do |name|
          Schema::Observation.new(name: name, role: :searchable, native_type: "fulltext", location: table)
        end
      end

      def write(index, document, routing: nil)
        key = index.source.storage_key(document.id)
        columns = document.writable_field_names - key.keys

        model_for(index, routing: routing).upsert(key.merge(replacement_attributes(document, columns)))
      end

      def refresh(index_name)
        index = ActiveSearch.index(index_name)
        model = connection_model_for(index)
        connection = model.connection

        wait_for_population(connection, model.table_name)
      end

      def capabilities
        @capabilities ||= Capabilities.new(
          index_creation: true,
          collection_ranges: true,
          highlighting: false,
          highlight_snippet_units: [],
          highlight_per_field_markers: false,
          highlight_per_field_snippets: false,
          operator: false,
          max_result_window: options.fetch(:max_result_window, 10_000)
        )
      end

      private
        def wait_for_population(connection, table_name)
          start_population(connection, table_name)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + options.fetch(:population_timeout, 120)
          loop do
            object_id = connection.select_value("SELECT OBJECT_ID(#{connection.quote(table_name)})").to_i
            pending_changes = connection.select_value(
              "SELECT OBJECTPROPERTYEX(#{object_id}, 'TableFulltextPendingChanges')"
            ).to_i
            population_status = connection.select_value(
              "SELECT OBJECTPROPERTYEX(#{object_id}, 'TableFulltextPopulateStatus')"
            ).to_i
            break if pending_changes.zero? && population_status.zero?

            if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
              raise ActiveRecord::StatementTimeout,
                "SQL Server full-text population timed out for #{table_name} " \
                  "(pending changes: #{pending_changes}, population status: #{population_status})"
            end

            sleep 0.05
          end
        end

        def start_population(connection, table_name)
          quoted_table = connection.quote_table_name(table_name)
          object_id = connection.select_value("SELECT OBJECT_ID(#{connection.quote(table_name)})").to_i
          item_count = connection.select_value(
            "SELECT OBJECTPROPERTYEX(#{object_id}, 'TableFulltextItemCount')"
          ).to_i
          row_count = connection.select_value("SELECT COUNT_BIG(*) FROM #{quoted_table}").to_i
          population = item_count.zero? && row_count.positive? ? "FULL" : "UPDATE"

          connection.execute("ALTER FULLTEXT INDEX ON #{quoted_table} START #{population} POPULATION")
        end

        def fulltext_key_index_name(table_name)
          "index_#{table_name}_on_id_for_fulltext"
        end
    end
  end
end
