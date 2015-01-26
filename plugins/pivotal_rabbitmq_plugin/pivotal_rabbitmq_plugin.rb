#! /usr/bin/env ruby
#
# The MIT License
#
# Copyright (c) 2013-2014 Pivotal Software, Inc.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#


require 'rubygems'
require 'bundler/setup'
require 'newrelic_plugin'
require 'rabbitmq_manager'
require 'uri'

module NewRelic
  module RabbitMQPlugin
    class Agent < NewRelic::Plugin::Agent::Base
      agent_guid 'com.indigobio.newrelic.plugin.rabbitmq'
      agent_version '1.0.5'
      agent_config_options :management_api_url, :debug, :filter
      agent_human_labels('RabbitMQ') do
        uri = URI.parse(management_api_url)
        "#{uri.host}"
      end

      def poll_cycle
        begin
          if "#{self.debug}" == "true" 
            puts "[RabbitMQ] Debug Mode On: Metric data will not be sent to new relic"
          end

          report_metric_check_debug 'Queued Messages/Ready', 'messages', queue_size_ready
          report_metric_check_debug 'Queued Messages/Unacknowledged', 'messages', queue_size_unacknowledged

          report_metric_check_debug 'Message Rate/Acknowledge', 'messages/sec', ack_rate
          report_metric_check_debug 'Message Rate/Confirm', 'messages/sec', confirm_rate
          report_metric_check_debug 'Message Rate/Deliver', 'messages/sec', deliver_rate
          report_metric_check_debug 'Message Rate/Redeliver', 'messages/sec', redeliver_rate
          report_metric_check_debug 'Message Rate/Publish', 'messages/sec', publish_rate
          report_metric_check_debug 'Message Rate/Return', 'messages/sec', return_unroutable_rate

          report_metric_check_debug 'Node/File Descriptors', 'file_descriptors', node_info('fd_used')
          report_metric_check_debug 'Node/Sockets', 'sockets', node_info('sockets_used')
          report_metric_check_debug 'Node/Erlang Processes', 'processes', node_info('proc_used')
          report_metric_check_debug 'Node/Memory Used', 'bytes', node_info('mem_used')

          report_queues

        rescue Exception => e
          $stderr.puts "[RabbitMQ] Exception while processing metrics. Check configuration."
          $stderr.puts e.message  
          if "#{self.debug}" == "true"
            $stderr.puts e.backtrace.inspect
          end
        end
      end

      def report_metric_check_debug(metricname, metrictype, metricvalue)
        if "#{self.debug}" == "true"
          puts("Component/#{metricname}[#{metrictype}] : #{metricvalue}")
        else
          report_metric metricname, metrictype, metricvalue
        end
      end

      private

      def rmq_manager
        @rmq_manager ||= ::RabbitMQManager.new(management_api_url)
      end

      #
      # Queue size
      #
      def queue_size_for(type = nil)
        totals_key = 'messages'
        totals_key << "_#{type}" if type

        queue_totals = rmq_manager.overview['queue_totals']
        if queue_totals.size == 0
          $stderr.puts "[RabbitMQ] No data found for queue_totals[#{totals_key}]. Check that queues are declared. No data will be reported."
        else
          queue_totals[totals_key] || 0
        end
      end

      def queue_size_ready
        queue_size_for 'ready'
      end

      def queue_size_unacknowledged
        queue_size_for 'unacknowledged'
      end

      #
      # Open-ended queues indicate problems (so do redeliveries but wonky clients redeliver messages)
      #
      def has_consumers?(queue)
        count(queue['consumers']) > 0
      end

      #
      # Rates
      #
      def ack_rate(queue = nil)
        rate_for('ack', queue)
      end

      def confirm_rate(queue = nil)
        rate_for('confirm', queue)
      end

      def deliver_rate(queue = nil)
        rate_for('deliver', queue)
      end

      def redeliver_rate(queue = nil)
        rate_for('redeliver', queue)
      end

      def publish_rate(queue = nil)
        rate_for('publish', queue)
      end

      def get_rate(queue = nil)
        rate_for('deliver_get', queue)
      end

      def rate_for(type, queue = nil)
        if queue.nil?
          msg_stats = rmq_manager.overview['message_stats']
        else
          msg_stats = queue['message_stats']
        end

        if msg_stats.is_a?(Hash)
          details = msg_stats["#{type}_details"]
          details ? details['rate'] : 0
        else
          0
        end
      end

      def return_unroutable_rate
        rate_for 'return_unroutable'
      end

      #
      # Node info
      #
      def node_info(key)
        default_node_name = rmq_manager.overview['node']
        node = rmq_manager.node(default_node_name)
        node[key]
      end

      def user_count
        rmq_manager.users.length
      end

      def count(value)
        value.nil? ? 0 : value
      end

      def report_queues
        return unless rmq_manager.queues.length > 0
        consumerless_queues = []
        self.filter << 'amq.gen'
        rmq_manager.queues.each do |q|
          next unless self.filter.select { |name| name =~ /#{q}/ }.empty?
          report_metric_check_debug 'Queue' + q['vhost'] + q['name'] + '/Messages/Ready', 'message', count(q['messages_ready'])
          report_metric_check_debug 'Queue' + q['vhost'] + q['name'] + '/Memory', 'bytes', count(q['memory'])
          report_metric_check_debug 'Queue' + q['vhost'] + q['name'] + '/Messages/Total', 'message', count(q['messages'])
          report_metric_check_debug 'Queue' + q['vhost'] + q['name'] + '/Consumers/Total', 'consumers', count(q['consumers'])
          report_metric_check_debug 'Queue' + q['vhost'] + q['name'] + '/Consumers/Active', 'consumers', count(q['active_consumers'])
          report_metric_check_debug 'Queue' + q['vhost'] + q['name'] + '/Message Rate/Acknowledge', 'messages/sec', ack_rate(q)
          report_metric_check_debug 'Queue' + q['vhost'] + q['name'] + '/Message Rate/Deliver', 'messages/sec', deliver_rate(q)
          report_metric_check_debug 'Queue' + q['vhost'] + q['name'] + '/Message Rate/Redeliver', 'messages/sec', redeliver_rate(q)
          report_metric_check_debug 'Queue' + q['vhost'] + q['name'] + '/Message Rate/Publish', 'messages/sec', publish_rate(q)
          report_metric_check_debug 'Queue' + q['vhost'] + q['name'] + '/Message Rate/Get', 'messages/sec', get_rate(q)
          consumerless_queues << q unless has_consumers?(q)
        end
        report_metric_check_debug 'Consumerless Queues', 'queues', consumerless_queues.count
      end
    end

    NewRelic::Plugin::Setup.install_agent :rabbitmq, self

    #
    # Launch the agent; this never returns.
    #
    if __FILE__==$0
      NewRelic::Plugin::Run.setup_and_run
    end
  end
end
