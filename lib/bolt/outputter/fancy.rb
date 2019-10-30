require 'bolt/pal'
require 'colored'

module Bolt
  class Outputter
    class Fancy < Bolt::Outputter

      INDENT_SIZE = 2

      def initialize(color, verbose, trace, stream = $stdout)
        super
        @indent = 0
        @step_index = 0
        @plan_index = 0
        @node_index = 1
        @output = true
        require 'terminfo'
        @term_size = TermInfo.screen_size[1]
      end

      def newline
        @stream.puts
      end

      def indent(&block)
        @indent += 1
        begin
          block.call
        rescue Exception => e
          log e, :red
          @indent -= 1
          raise e
        end
        @indent -= 1
      end

      def process_kind(log)
        output = ""
        if log =~ ResultSet and log.kind and log.msg
          output << "[#{log.kind}] #{log.msg}"
          if details = log.details
            output << "\nDetails:\n"
            details.each do |k, v|
              output << "  #{k}: #{v}"
            end
          end
        else
          output = log
        end
        return output
      end

      def log(string, color = nil, *options)

        string = string.to_s
        if string.include? "\n"
          string.split("\n").each{|x| log(x, color, *options)}
          return
        end

        indent_spaces = ' ' * INDENT_SIZE * @indent
        message = indent_spaces + string

        if options.include? :title
          message << ' '
          message = message.ljust(@term_size, '*')
          options.delete(:title)
        end

        if color.nil?
          @stream.puts(message)
        else
          @stream.puts(message.send(color))
        end

      end

      def print_head()
      end

      def print_table(results)
        require 'terminal-table'
        log Terminal::Table.new(
          rows: results,
          style: {
            border_x: '',
            border_y: '',
            border_i: '',
            padding_left: 0,
            padding_right: 3,
            border_top: false,
            border_bottom: false,
          }
        )
      end

      def handle_event(event)
        case event[:type]
        when :message then print_message_event(event)
        when :node_start then print_start(event[:target])
        when :node_result then print_result(event[:result])
        when :step_start then print_step_start(event)
        when :step_finish then print_step_finish(event)
        when :plan_start then print_plan_start(event)
        when :plan_finish then print_plan_finish(event)
        when :enable_default_output then @output = true
        when :disable_default_output then @output = false
        else log event, :magenta
        end
      end

      def print_start(target)
      end

      # Plans
      def print_plan_start(event)
        plan = @plan_index == 0 ? 'Plan' : "SubPlan #{@plan_index}"
        log "[#{plan}] #{event[:plan]} {", :green, :title
        @plan_index += 1
        @indent += 1
      end

      def print_plan_finish(event)
        @indent -= 1
        log "}", :green, :title
        @plan_index -= 1
      end

      def print_plan_result(resultset)
        value = resultset.value
        case value
        when NilClass then log("No result")
        when Bolt::ApplyFailure then log(value.message, :red)
        when Bolt::ResultSet
          value.each do |result|
            result.ok_set.names.each do |name|
              log("[#{name}] OK", :green)
            end
            result.error_set.names.each do |name|
              log("[#{name}] FAILURE", :red)
            end
          end
        when Bolt::Error
          print_error(value)
        else
          log "[#{resultset.class}][#{value.class}]" + process_kind(resultset), :magenta
        end
      end

      def print_plans(plans, modulepath)
        print_table(plans)
        log "MODULEPATH: #{modulepath.join(File::PATH_SEPARATOR)}"
        log "Use `bolt task show <task-name>` to view\ndetails and parameters for a specific task.", :yellow
      end

      def print_plan_info(plan)
        usage = [] << "bolt plan run #{plan['name']}"
        pretty_params = []
        plan['parameters'].each do |name, p|
          pretty_params << "- #{name}: #{p['type']}"
          usage << (p.include?('default_value') ? "[#{name}=<value>]" : "#{name}=<value>")
        end
        usage = usage.join(' ')
        pretty_params = pretty_params.join("\n")

        newline
        log "#{plan['name']}", :blue
        2.times { newline }
        log "USAGE: #{usage}"
        log "PARAMETERS:\n#{pretty_params}" if plan['parameters']
      end

      # Messages
      def print_message_event(event)
        log "[out::message] #{event[:message]}", :blue
      end

      def print_message(message)
        log message
      end

      # Steps / Tasks
      def print_step_start(event)
        @step_index = 0
        log "[Step] #{event[:description]} {", :blue, :title
        #@indent += 1
      end

      def print_step_finish(event)
        #@indent -= 1
        log '}', :blue, :title
        newline
        @step_index += 1
        @node_index = 1
      end

      def print_tasks(tasks, modulepath)
        print_table(tasks)
        log "MODULEPATH: #{modulepath.join(File::PATH_SEPARATOR)}"
        log "Use `bolt task show <task-name>` to view\ndetails and parameters for a specific task.", :yellow
      end

      def print_task_info(task)
        usage = [] << "bolt task #{task['name']} --nodes <node-name>"
        pretty_params = []
        task['metadata']['parameters'].each do |name, p|
          pretty_params << "- #{name}: #{p['type'] || 'Any'}"
          pretty_params << "    #{p['description']}" if p['description']
          usage << (p['type'].is_a? Puppet::Pops::Types::POptionalType ? "[#{name}=<value>]" : "#{name}=<value>")
        end
        usage << "[--noop]" if task['metadata']['supports_noop']

        usage = usage.join(' ')
        pretty_params = pretty_params.join("\n")

        newline
        log "#{task['name']}", :blue
        2.times { newline }
        log "USAGE: #{usage}"
        log "PARAMETERS:\n#{pretty_params}" if task['parameters']
      end

      # Puppet apply
      def print_puppet(report)
        report['logs'].each do |entry|
          color = case entry['level']
          when 'err' then :red
          when 'notice' then nil
          else nil
          end
          log "#{entry['source']}: #{entry['message']}", color
        end
      end

      def color_object(obj)
        case obj
        when Hash
          return '{' + obj.map{|k, v| k.green + ': '.red + color_object(v) }.join(', ') + '}'
        when Array
          return '[' + obj.map{|x| color_object(x)}.join(', ') + ']'
        when String
          return '"' + obj.cyan + '"'
        when Numeric
          return obj.to_s.cyan
        when NilClass
          return 'null'.magenta
        when TrueClass, FalseClass
          return obj.to_s.blue
        else
          return obj
        end
      end

      # Results
      def print_result(result)
        # Host
        index = "[#{@node_index}]".cyan
        time = (result['time'] || DateTime.now).strftime('%H:%M:%S')
        state = case
        when (report = result['report'] and report['status'] == 'unchanged')
          '[UNCHANGED]'.blue
        when result.success?
          '[SUCCESS]'.green
        else
          '[FAILURE]'.red
        end
        host = result.target.host
        log  [index, time, state, host].join(' ')
        @node_index += 1

        # Puppet report
        if report = result['report']
          indent { print_puppet(report) }
        elsif error = result.value['_error']
          indent { print_error(error) }
        elsif result.generic_value
          indent { log color_object(result.generic_value) }
        # Non structured output
        elsif @output and output = result.value['_output']
          indent { log output }
        elsif message = result['message']
          indent { log message }
        else
          indent { log result.class, :magenta ; log result, :magenta }
        end

      end

      def print_error(error)
        case error
        when Bolt::Error
          value = error
          log "[#{value.kind}] ".red + "#{value.msg}"
        when Hash
          if %w[kind issue_code msg details].map{|k| error.keys.include? k}.all?
            log "[#{error['kind']}]".red + "[#{error['issue_code']}] ".red + error['msg']
          else
            log error.to_json.red
          end
        else
          log error.to_s.red
        end
      end

      def print_puppetfile_result(success, puppetfile, moduledir)
        if success
          log "Successfully synced modules from #{puppetfile.to_s} to #{moduledir}", :green
        else
          log "Failed to sync modules from #{puppetfile.to_s} to #{moduledir}", :red
        end
      end

      def fatal_error(err)
        log '[fatal_error]', :magenta
        log err.message, :red
        if err.is_a? Bolt::RunFailure
          log ::JSON.pretty_generate(err.result_set)
        end

        if @trace and err.backtrace
          indent { log err.backtrace.join("\n"), :red }
        end
      end

      # Misc
      def print_head
      end

      def print_summary(results, elapsed_time = nil)
        ok_set = results.ok_set
        unless ok_set.empty?
          log "Successful on #{ok_set.size} node(s): #{ok_set.names.join(',')}", :green
        end
        error_set = results.error_set
        unless error_set.empty?
          log "Failed on #{error_set.size} node(s): #{error_set.names.join(',')}", :red
        end
      end

      def print_module_list(module_list)
      end

      def print_targets(options)
        targets = options[:targets].map(&:name)
        count = "#{targets.count} target#{'s' unless targets.count == 1}"
        log targets.join("\n")
        log count, :green
      end

      def print_apply_result(apply_result, elapsed_time)
        print_summary(apply_result, elapsed_time)
      end

    end
  end
end
