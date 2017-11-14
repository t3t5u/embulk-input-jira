require "perfect_retry"
require "embulk/input/jira_input_plugin_utils"
require "embulk/input/jira_api"

module Embulk
  module Input
    class Jira < InputPlugin
      PER_PAGE = 50
      GUESS_RECORDS_COUNT = 10
      PREVIEW_RECORDS_COUNT = 15

      Plugin.register_input("jira", self)

      def self.transaction(config, &control)
        task = {
          username: config.param(:username, :string),
          password: config.param(:password, :string),
          uri: config.param(:uri, :string),
          jql: config.param(:jql, :string),
        }

        attributes = {}
        columns = config.param(:columns, :array).map do |column|
          name = column["name"]
          type = column["type"].to_sym
          attributes[name] = type
          Column.new(nil, name, type, column["format"])
        end

        task[:attributes] = attributes
        task[:retry_limit] = config.param(:retry_limit, :integer, default: 5)
        task[:retry_initial_wait_sec] = config.param(:retry_initial_wait_sec, :integer, default: 1)

        resume(task, columns, 1, &control)
      end

      def self.resume(task, columns, count, &control)
        task_reports = yield(task, columns, count)

        next_config_diff = {}
        return next_config_diff
      end

      def self.guess(config)
        username = config.param(:username, :string)
        password = config.param(:password, :string)
        uri = config.param(:uri, :string)
        jql = config.param(:jql, :string)

        jira = JiraApi::Client.setup do |jira_config|
          # TODO: api_version should be 2 (the latest version)
          # auth_type should be specified from config. (The future task)

          jira_config.username = username
          jira_config.password = password
          jira_config.uri = uri
          jira_config.api_version = "latest"
          jira_config.auth_type = "basic"
        end

        retry_limit = config.param(:retry_limit, :integer, default: 5)
        retry_initial_wait_sec = config.param(:retry_initial_wait_sec, :integer, default: 1)
        retryer = retryer(retry_limit, retry_initial_wait_sec)

        # Get credential before going to search issue
        jira.check_user_credential(username)

        # TODO: we use 0..10 issues to guess config?
        records = retryer.with_retry do
          jira.search_issues(jql, max_results: GUESS_RECORDS_COUNT).map do |issue|
            issue.to_record
          end
        end

        columns = JiraInputPluginUtils.guess_columns(records)

        guessed_config = {
          "columns" => columns,
        }

        return guessed_config
      end

      def init
        @attributes = task[:attributes]
        @jira = JiraApi::Client.setup do |config|
          config.username = task[:username]
          config.password = task[:password]
          config.uri = task[:uri]
          config.api_version = "latest"
          config.auth_type = "basic"
        end
        @jql = task[:jql]
        @retryer = self.class.retryer(task[:retry_limit], task[:retry_initial_wait_sec])
      end

      def run
        return preview if preview?

        @jira.check_user_credential(task[:username])
        options = {}
        total_count = @jira.total_count(@jql)
        last_page = (total_count.to_f / PER_PAGE).ceil

        0.step(total_count, PER_PAGE).with_index(1) do |start_at, page|
          logger.debug "Fetching #{page} / #{last_page} page"
          @retryer.with_retry do
            @jira.search_issues(@jql, options.merge(start_at: start_at)).each do |issue|
              values = @attributes.map do |(attribute_name, type)|
                JiraInputPluginUtils.cast(issue[attribute_name], type)
              end
              page_builder.add(values)
            end
          end
        end

        page_builder.finish

        task_report = {}
        return task_report
      end

      def self.logger
        Embulk.logger
      end

      def self.retryer(limit, initial_wait)
        PerfectRetry.new do |config|
          config.limit = limit
          config.sleep = proc{|n| initial_wait + (2 ** n)}
          config.dont_rescues = [Embulk::ConfigError, Embulk::DataError]
          config.logger = Embulk.logger
          config.log_level = nil
        end
      end

      def logger
        self.class.logger
      end

      private

      def preview
        @jira.check_user_credential(task[:username])

        logger.debug "For preview mode, JIRA input plugin fetches records at most #{PREVIEW_RECORDS_COUNT}"
        @jira.search_issues(@jql, max_results: PREVIEW_RECORDS_COUNT).each do |issue|
          values = @attributes.map do |(attribute_name, type)|
            JiraInputPluginUtils.cast(issue[attribute_name], type)
          end
          page_builder.add(values)
        end
        page_builder.finish

        task_report = {}
        return task_report
      end

      def preview?
        begin
          # http://www.embulk.org/docs/release/release-0.6.12.html
          org.embulk.spi.Exec.isPreview()
        rescue java.lang.NullPointerException => e
          false
        end
      end
    end
  end
end
