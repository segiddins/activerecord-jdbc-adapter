ArJdbc.load_java_part :HSQLDB
require 'arjdbc/hsqldb/explain_support'
require 'arjdbc/hsqldb/schema_creation' # AR 4.x
require 'arel/visitors/hsqldb'

module ArJdbc
  module HSQLDB
    include ExplainSupport

    # @see ActiveRecord::ConnectionAdapters::JdbcColumn#column_types
    def self.column_selector
      [ /hsqldb/i, lambda { |config, column| column.extend(Column) } ]
    end

    # @see ActiveRecord::ConnectionAdapters::JdbcColumn
    module Column

      private

      def extract_limit(sql_type)
        limit = super
        case @sql_type = sql_type.downcase
        when /^tinyint/i     then @sql_type = 'tinyint'; limit = 1
        when /^smallint/i    then @sql_type = 'smallint'; limit = 2
        when /^bigint/i      then @sql_type = 'bigint'; limit = 8
        when /^double/i      then @sql_type = 'double'; limit = 8
        when /^real/i        then @sql_type = 'real'; limit = 8
        # NOTE: once again we get incorrect "limits" from HypesSQL's JDBC
        # thus yet again we need to fix incorrectly detected limits :
        when /^integer/i     then @sql_type = 'integer'; limit = 4
        when /^float/i       then @sql_type = 'float';   limit = 8
        when /^decimal/i     then @sql_type = 'decimal';
        when /^datetime/i    then @sql_type = 'datetime'; limit = nil
        when /^timestamp/i   then @sql_type = 'timestamp'; limit = nil
        when /^time/i        then @sql_type = 'time'; limit = nil
        when /^date/i        then @sql_type = 'date'; limit = nil
        else
          # HSQLDB appears to return "LONGVARCHAR(0)" for :text columns,
          # which for AR purposes should be interpreted as "no limit" :
          limit = nil if sql_type =~ /\(0\)$/
        end
        limit
      end

      # Post process default value from JDBC into a Rails-friendly format (columns{-internal})
      def default_value(value)
        # JDBC returns column default strings with actual single quotes around the value.
        return $1 if value =~ /^'(.*)'$/
        value
      end

    end

    ADAPTER_NAME = 'HSQLDB'.freeze

    def adapter_name
      ADAPTER_NAME
    end

    NATIVE_DATABASE_TYPES = {
      :primary_key => "integer GENERATED BY DEFAULT AS IDENTITY(START WITH 0) PRIMARY KEY",
      :string => { :name => "varchar", :limit => 255 }, # :limit => 2147483647
      :text => { :name => "clob" },
      :binary => { :name => "blob" },
      :boolean => { :name => "boolean" }, # :name => "tinyint", :limit => 1
      :bit => { :name=>"bit" }, # stored as 0/1 on HSQLDB 2.2 (translates true/false)
      :integer => { :name => "integer", :limit => 4 },
      :decimal => { :name => "decimal" }, # :limit => 2147483647
      :numeric => { :name => "numeric" }, # :limit => 2147483647
      # NOTE: fix incorrectly detected limits :
      :tinyint => { :name => "tinyint", :limit => 1 },
      :smallint => { :name => "smallint", :limit => 2 },
      :bigint => { :name => "bigint", :limit => 8 },
      :float => { :name => "float" },
      :double => { :name => "double", :limit => 8 },
      :real => { :name => "real", :limit => 8 },
      :date => { :name=>"date" },
      :time => { :name=>"time" },
      :timestamp => { :name=>"timestamp" },
      :datetime => { :name=>"timestamp" },
      :other => { :name=>"other" },
      # NOTE: would be great if AR allowed as to refactor as :
      #   t.column :string, :ignorecase => true
      :character => { :name => "character" },
      :varchar_ignorecase => { :name => "varchar_ignorecase" },
    }

    # @override
    def native_database_types
      NATIVE_DATABASE_TYPES
    end

    # @override
    def quote(value, column = nil)
      return value.quoted_id if value.respond_to?(:quoted_id)
      return value if sql_literal?(value)

      case value
      when String
        column_type = column && column.type
        if column_type == :binary
          "X'#{value.unpack("H*")[0]}'"
        elsif column_type == :integer ||
            column.respond_to?(:primary) && column.primary && column.klass != String
          value.to_i.to_s
        else
          "'#{quote_string(value)}'"
        end
      when Time
        column_type = column && column.type
        if column_type == :time
          "'#{value.strftime("%H:%M:%S")}'"
        #elsif column_type == :timestamp # || column_type == :datetime
          #value = ::ActiveRecord.default_timezone == :utc ? value.getutc : value.getlocal
          #"'#{value.strftime("%Y-%m-%d %H:%M:%S")}.#{sprintf("%06d", value.usec)}'"
        else
          super
        end
      else
        super
      end
    end

    # Quote date/time values for use in SQL input.
    # Includes microseconds if the value is a Time responding to usec.
    # @override
    def quoted_date(value)
      if value.acts_like?(:time) && value.respond_to?(:usec)
        usec = sprintf("%06d", value.usec)
        value = ::ActiveRecord.default_timezone == :utc ? value.getutc : value.getlocal
        "#{value.strftime("%Y-%m-%d %H:%M:%S")}.#{usec}"
      else
        super
      end
    end if ::ActiveRecord::VERSION::MAJOR >= 3

    # @override
    def quote_column_name(name)
      name = name.to_s
      if name =~ /[-]/
        %Q{"#{name.upcase}"}
      else
        name
      end
    end

    # @override
    def add_column(table_name, column_name, type, options = {})
      add_column_sql = "ALTER TABLE #{quote_table_name(table_name)} ADD #{quote_column_name(column_name)} #{type_to_sql(type, options[:limit], options[:precision], options[:scale])}"
      add_column_options!(add_column_sql, options)
      execute(add_column_sql)
    end unless const_defined? :SchemaCreation

    # @override
    def change_column(table_name, column_name, type, options = {})
      execute "ALTER TABLE #{table_name} ALTER COLUMN #{column_name} #{type_to_sql(type, options[:limit])}"
    end

    def change_column_default(table_name, column_name, default) #:nodoc:
      execute "ALTER TABLE #{table_name} ALTER COLUMN #{column_name} SET DEFAULT #{quote(default)}"
    end

    # @override
    def rename_column(table_name, column_name, new_column_name) #:nodoc:
      execute "ALTER TABLE #{table_name} ALTER COLUMN #{column_name} RENAME TO #{new_column_name}"
    end

    # @override
    def type_to_sql(type, limit = nil, precision = nil, scale = nil)
      return super if defined?(::Jdbc::H2) || type.to_s != 'integer' || limit == nil
      type
    end

    # @override
    def rename_table(name, new_name)
      execute "ALTER TABLE #{name} RENAME TO #{new_name}"
    end

    # @note AR API since 4.2
    def truncate(table_name, name = nil)
      execute "TRUNCATE TABLE #{quote_table_name(table_name)}", name
    end

    def last_insert_id
      identity = select_value("CALL IDENTITY()")
      Integer(identity.nil? ? 0 : identity)
    end

    # @private
    def _execute(sql, name = nil)
      result = super
      self.class.insert?(sql) ? last_insert_id : result
    end
    private :_execute

    # @note Only used with (non-AREL) ActiveRecord **2.3**.
    # @see Arel::Visitors::HSQLDB#limit_offset
    def add_limit_offset!(sql, options)
      if sql =~ /^select/i
        offset = options[:offset] || 0
        if limit = options[:limit]
          sql.replace "SELECT LIMIT #{offset} #{limit} #{sql[7..-1]}"
        elsif offset > 0
          sql.replace "SELECT LIMIT #{offset} 0 #{sql[7..-1]}"
        end
      end
    end if ::ActiveRecord::VERSION::MAJOR < 3

    # @override
    def empty_insert_statement_value
      # on HSQLDB only work with tables that have a default value for each
      # and every column ... you'll need to avoid `Model.create!` on 4.0
      'DEFAULT VALUES'
    end

    # We filter out HSQLDB's system tables (named "SYSTEM.*").
    # @override
    def tables
      @connection.tables.select { |row| row.to_s !~ /^system_/i }
    end

    # @override
    def remove_index(table_name, options = {})
      execute "DROP INDEX #{quote_column_name(index_name(table_name, options))}"
    end

    # @override
    def supports_views?; true end

    # @override
    def supports_foreign_keys?; true end

    # @override
    def structure_dump
      execute('SCRIPT').map do |result|
        # [ { 'command' => SQL }, { 'command' ... }, ... ]
        case sql = result.first[1] # ['command']
        when /CREATE USER SA PASSWORD DIGEST .*?/i then nil
        when /CREATE SCHEMA PUBLIC AUTHORIZATION DBA/i then nil
        when /GRANT DBA TO SA/i then nil
        else sql
        end
      end.compact.join("\n\n")
    end

    # @see #structure_dump
    def structure_load(dump)
      dump.each_line("\n\n") { |ddl| execute(ddl) }
    end

    def shutdown
      execute 'SHUTDOWN'
    end

    # @private
    def recreate_database(name = nil, options = {})
      drop_database(name)
      create_database(name, options)
    end

    # @private
    def create_database(name = nil, options = {}); end

    # @private
    def drop_database(name = nil)
      execute('DROP SCHEMA PUBLIC CASCADE')
    end

  end
end

module ActiveRecord::ConnectionAdapters

  class HsqldbAdapter < JdbcAdapter
    include ArJdbc::HSQLDB

    def arel_visitor # :nodoc:
      Arel::Visitors::HSQLDB
    end
  end

end

