# Copyright 2016 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


require "google/cloud/spanner/errors"
require "google/cloud/spanner/credentials"
require "google/cloud/spanner/version"
require "google/cloud/spanner/v1"
require "google/cloud/spanner/admin/instance/v1"
require "google/cloud/spanner/admin/database/v1"
require "google/cloud/spanner/convert"
require "google/cloud/spanner/lar_headers"

module Google
  module Cloud
    module Spanner
      ##
      # @private Represents the gRPC Spanner service, including all the API
      # methods.
      class Service
        attr_accessor :project
        attr_accessor :credentials
        attr_accessor :timeout
        attr_accessor :host
        attr_accessor :lib_name
        attr_accessor :lib_version
        attr_accessor :quota_project
        attr_accessor :enable_leader_aware_routing

        attr_reader :universe_domain

        RST_STREAM_INTERNAL_ERROR = "Received RST_STREAM".freeze
        EOS_INTERNAL_ERROR = "Received unexpected EOS on DATA frame from server".freeze

        ##
        # Creates a new Service instance.
        def initialize project, credentials, quota_project: nil,
                       host: nil, timeout: nil, lib_name: nil, lib_version: nil,
                       enable_leader_aware_routing: nil, universe_domain: nil
          @project = project
          @credentials = credentials
          @quota_project = quota_project || (credentials.quota_project_id if credentials.respond_to? :quota_project_id)
          # TODO: This logic is part of UniverseDomainConcerns in gapic-common
          # but is being copied here because we need to determine the host up
          # front in order to build a gRPC channel. We should refactor this
          # somehow to allow this logic to live where it is supposed to.
          @universe_domain = universe_domain || ENV["GOOGLE_CLOUD_UNIVERSE_DOMAIN"] || "googleapis.com"
          @host = host ||
                  Google::Cloud::Spanner::V1::Spanner::Client::DEFAULT_ENDPOINT_TEMPLATE.sub(
                    Gapic::UniverseDomainConcerns::ENDPOINT_SUBSTITUTION, @universe_domain
                  )
          @timeout = timeout
          @lib_name = lib_name
          @lib_version = lib_version
          @enable_leader_aware_routing = enable_leader_aware_routing
        end

        def channel
          require "grpc"
          GRPC::Core::Channel.new host, chan_args, chan_creds
        end

        def chan_args
          { "grpc.service_config_disable_resolution" => 1 }
        end

        def chan_creds
          return credentials if insecure?
          require "grpc"
          GRPC::Core::ChannelCredentials.new.compose \
            GRPC::Core::CallCredentials.new credentials.client.updater_proc
        end

        def service
          return mocked_service if mocked_service
          @service ||=
            V1::Spanner::Client.new do |config|
              config.credentials = channel
              config.quota_project = @quota_project
              config.timeout = timeout if timeout
              config.endpoint = host if host
              config.universe_domain = @universe_domain
              config.lib_name = lib_name_with_prefix
              config.lib_version = Google::Cloud::Spanner::VERSION
              config.metadata = { "google-cloud-resource-prefix" => "projects/#{@project}" }
            end
        end
        attr_accessor :mocked_service

        def instances
          return mocked_instances if mocked_instances
          @instances ||=
            Admin::Instance::V1::InstanceAdmin::Client.new do |config|
              config.credentials = channel
              config.quota_project = @quota_project
              config.timeout = timeout if timeout
              config.endpoint = host if host
              config.universe_domain = @universe_domain
              config.lib_name = lib_name_with_prefix
              config.lib_version = Google::Cloud::Spanner::VERSION
              config.metadata = { "google-cloud-resource-prefix" => "projects/#{@project}" }
            end
        end
        attr_accessor :mocked_instances

        def databases
          return mocked_databases if mocked_databases
          @databases ||=
            Admin::Database::V1::DatabaseAdmin::Client.new do |config|
              config.credentials = channel
              config.quota_project = @quota_project
              config.timeout = timeout if timeout
              config.endpoint = host if host
              config.universe_domain = @universe_domain
              config.lib_name = lib_name_with_prefix
              config.lib_version = Google::Cloud::Spanner::VERSION
              config.metadata = { "google-cloud-resource-prefix" => "projects/#{@project}" }
            end
        end
        attr_accessor :mocked_databases

        def insecure?
          credentials == :this_channel_is_insecure
        end

        def list_instances token: nil, max: nil, call_options: nil
          opts = default_options call_options: call_options
          request = {
            parent:     project_path,
            page_size:  max,
            page_token: token
          }
          paged_enum = instances.list_instances request, opts
          paged_enum.response
        end

        def get_instance name, call_options: nil
          opts = default_options call_options: call_options
          request = { name: instance_path(name) }
          instances.get_instance request, opts
        end

        def create_instance instance_id, name: nil, config: nil, nodes: nil,
                            processing_units: nil, labels: nil,
                            call_options: nil
          opts = default_options call_options: call_options
          labels = labels.to_h { |k, v| [String(k), String(v)] } if labels

          create_obj = Admin::Instance::V1::Instance.new({
            display_name: name, config: instance_config_path(config),
            node_count: nodes, processing_units: processing_units,
            labels: labels
          }.compact)

          request = {
            parent:      project_path,
            instance_id: instance_id,
            instance:    create_obj
          }
          instances.create_instance request, opts
        end

        def update_instance instance, field_mask: nil, call_options: nil
          opts = default_options call_options: call_options

          if field_mask.nil? || field_mask.empty?
            field_mask = %w[display_name node_count labels]
          end

          request = {
            instance: instance,
            field_mask: Google::Protobuf::FieldMask.new(paths: field_mask)
          }
          instances.update_instance request, opts
        end

        def delete_instance name, call_options: nil
          opts = default_options call_options: call_options
          request = { name: instance_path(name) }
          instances.delete_instance request, opts
        end

        def get_instance_policy name, call_options: nil
          opts = default_options call_options: call_options
          request = { resource: instance_path(name) }
          instances.get_iam_policy request, opts
        end

        def set_instance_policy name, new_policy, call_options: nil
          opts = default_options call_options: call_options
          request = {
            resource: instance_path(name),
            policy:  new_policy
          }
          instances.set_iam_policy request, opts
        end

        def test_instance_permissions name, permissions, call_options: nil
          opts = default_options call_options: call_options
          request = {
            resource:    instance_path(name),
            permissions: permissions
          }
          instances.test_iam_permissions request, opts
        end

        def list_instance_configs token: nil, max: nil, call_options: nil
          opts = default_options call_options: call_options
          request = { parent: project_path, page_size: max, page_token: token }
          paged_enum = instances.list_instance_configs request, opts
          paged_enum.response
        end

        def get_instance_config name, call_options: nil
          opts = default_options call_options: call_options
          request = { name: instance_config_path(name) }
          instances.get_instance_config request, opts
        end

        def list_databases instance_id, token: nil, max: nil, call_options: nil
          opts = default_options call_options: call_options
          request = {
            parent:     instance_path(instance_id),
            page_size:  max,
            page_token: token
          }
          paged_enum = databases.list_databases request, opts
          paged_enum.response
        end

        def get_database instance_id, database_id, call_options: nil
          opts = default_options call_options: call_options
          request = { name: database_path(instance_id, database_id) }
          databases.get_database request, opts
        end

        def create_database instance_id, database_id, statements: [],
                            call_options: nil, encryption_config: nil
          opts = default_options call_options: call_options
          request = {
            parent: instance_path(instance_id),
            create_statement: "CREATE DATABASE `#{database_id}`",
            extra_statements: Array(statements),
            encryption_config: encryption_config
          }
          databases.create_database request, opts
        end

        def drop_database instance_id, database_id, call_options: nil
          opts = default_options call_options: call_options
          request = { database: database_path(instance_id, database_id) }
          databases.drop_database request, opts
        end

        def get_database_ddl instance_id, database_id, call_options: nil
          opts = default_options call_options: call_options
          request = { database: database_path(instance_id, database_id) }
          databases.get_database_ddl request, opts
        end

        def update_database_ddl instance_id, database_id, statements: [],
                                operation_id: nil, call_options: nil, descriptor_set: nil
          bin_data =
            case descriptor_set
            when Google::Protobuf::FileDescriptorSet
              Google::Protobuf::FileDescriptorSet.encode descriptor_set
            when String
              File.binread descriptor_set
            when NilClass
              nil
            else
              raise ArgumentError,
                    "A value of type #{descriptor_set.class} is not supported."
            end

          proto_descriptors = bin_data unless bin_data.nil?
          opts = default_options call_options: call_options
          request = {
            database: database_path(instance_id, database_id),
            statements: Array(statements),
            operation_id: operation_id,
            proto_descriptors: proto_descriptors
          }
          databases.update_database_ddl request, opts
        end

        def get_database_policy instance_id, database_id, call_options: nil
          opts = default_options call_options: call_options
          request = { resource: database_path(instance_id, database_id) }
          databases.get_iam_policy request, opts
        end

        def set_database_policy instance_id, database_id, new_policy,
                                call_options: nil
          opts = default_options call_options: call_options
          request = {
            resource: database_path(instance_id, database_id),
            policy:   new_policy
          }
          databases.set_iam_policy request, opts
        end

        def test_database_permissions instance_id, database_id, permissions,
                                      call_options: nil
          opts = default_options call_options: call_options
          request = {
            resource:    database_path(instance_id, database_id),
            permissions: permissions
          }
          databases.test_iam_permissions request, opts
        end

        def get_session session_name, call_options: nil
          route_to_leader = LARHeaders.get_session
          opts = default_options session_name: session_name,
                                 call_options: call_options,
                                 route_to_leader: route_to_leader
          service.get_session({ name: session_name }, opts)
        end

        def create_session database_name, labels: nil,
                           call_options: nil, database_role: nil
          route_to_leader = LARHeaders.create_session
          opts = default_options session_name: database_name,
                                 call_options: call_options,
                                 route_to_leader: route_to_leader
          session = V1::Session.new labels: labels, creator_role: database_role if labels || database_role
          service.create_session(
            { database: database_name, session: session }, opts
          )
        end

        def batch_create_sessions database_name, session_count, labels: nil,
                                  call_options: nil, database_role: nil
          route_to_leader = LARHeaders.batch_create_sessions
          opts = default_options session_name: database_name,
                                 call_options: call_options,
                                 route_to_leader: route_to_leader
          session = V1::Session.new labels: labels, creator_role: database_role if labels || database_role
          # The response may have fewer sessions than requested in the RPC.
          request = {
            database: database_name,
            session_count: session_count,
            session_template: session
          }
          service.batch_create_sessions request, opts
        end

        def delete_session session_name, call_options: nil
          route_to_leader = LARHeaders.delete_session
          opts = default_options session_name: session_name,
                                 call_options: call_options,
                                 route_to_leader: route_to_leader
          service.delete_session({ name: session_name }, opts)
        end

        def execute_streaming_sql session_name, sql, transaction: nil,
                                  params: nil, types: nil, resume_token: nil,
                                  partition_token: nil, seqno: nil,
                                  query_options: nil, request_options: nil,
                                  call_options: nil, data_boost_enabled: nil,
                                  directed_read_options: nil,
                                  route_to_leader: nil
          opts = default_options session_name: session_name,
                                 call_options: call_options,
                                 route_to_leader: route_to_leader
          request =  {
            session: session_name,
            sql: sql,
            transaction: transaction,
            params: params,
            param_types: types,
            resume_token: resume_token,
            partition_token: partition_token,
            seqno: seqno,
            query_options: query_options,
            request_options: request_options,
            directed_read_options: directed_read_options
          }
          request[:data_boost_enabled] = data_boost_enabled unless data_boost_enabled.nil?
          service.execute_streaming_sql request, opts
        end

        def execute_batch_dml session_name, transaction, statements, seqno,
                              request_options: nil, call_options: nil
          route_to_leader = LARHeaders.execute_batch_dml
          opts = default_options session_name: session_name,
                                 call_options: call_options,
                                 route_to_leader: route_to_leader
          statements = statements.map(&:to_grpc)
          request = {
            session: session_name,
            transaction: transaction,
            statements: statements,
            seqno: seqno,
            request_options: request_options
          }
          service.execute_batch_dml request, opts
        end

        def streaming_read_table session_name, table_name, columns, keys: nil,
                                 index: nil, transaction: nil, limit: nil,
                                 resume_token: nil, partition_token: nil,
                                 request_options: nil, call_options: nil,
                                 data_boost_enabled: nil, directed_read_options: nil,
                                 route_to_leader: nil
          opts = default_options session_name: session_name,
                                 call_options: call_options,
                                 route_to_leader: route_to_leader
          request = {
            session: session_name, table: table_name, columns: columns,
            key_set: keys, transaction: transaction, index: index,
            limit: limit, resume_token: resume_token,
            partition_token: partition_token, request_options: request_options
          }
          request[:data_boost_enabled] = data_boost_enabled unless data_boost_enabled.nil?
          request[:directed_read_options] = directed_read_options unless directed_read_options.nil?
          service.streaming_read request, opts
        end

        def partition_read session_name, table_name, columns, transaction,
                           keys: nil, index: nil, partition_size_bytes: nil,
                           max_partitions: nil, call_options: nil
          partition_opts = partition_options partition_size_bytes,
                                             max_partitions
          route_to_leader = LARHeaders.partition_read
          opts = default_options session_name: session_name,
                                 call_options: call_options,
                                 route_to_leader: route_to_leader
          request = {
            session: session_name, table: table_name, key_set: keys,
            transaction: transaction, index: index, columns: columns,
            partition_options: partition_opts
          }
          service.partition_read request, opts
        end

        def partition_query session_name, sql, transaction, params: nil,
                            types: nil, partition_size_bytes: nil,
                            max_partitions: nil, call_options: nil
          partition_opts = partition_options partition_size_bytes,
                                             max_partitions
          route_to_leader = LARHeaders.partition_query
          opts = default_options session_name: session_name,
                                 call_options: call_options,
                                 route_to_leader: route_to_leader
          request = {
            session: session_name, sql: sql, transaction: transaction,
            params: params, param_types: types,
            partition_options: partition_opts
          }
          service.partition_query request, opts
        end

        def commit session_name, mutations = [],
                   transaction_id: nil, exclude_txn_from_change_streams: false,
                   commit_options: nil, request_options: nil, call_options: nil
          route_to_leader = LARHeaders.commit
          tx_opts = nil
          if transaction_id.nil?
            tx_opts = V1::TransactionOptions.new(
              read_write: V1::TransactionOptions::ReadWrite.new,
              exclude_txn_from_change_streams: exclude_txn_from_change_streams
            )
          end
          opts = default_options session_name: session_name,
                                 call_options: call_options,
                                 route_to_leader: route_to_leader
          request = {
            session: session_name, transaction_id: transaction_id,
            single_use_transaction: tx_opts, mutations: mutations,
            request_options: request_options
          }

          request = add_commit_options request, commit_options

          service.commit request, opts
        end

        def add_commit_options request, commit_options
          if commit_options
            if commit_options.key? :return_commit_stats
              request[:return_commit_stats] =
                commit_options[:return_commit_stats]
            end
            if commit_options.key? :max_commit_delay
              request[:max_commit_delay] =
                Convert.number_to_duration(commit_options[:max_commit_delay],
                                           millisecond: true)
            end
          end
          request
        end

        def rollback session_name, transaction_id, call_options: nil
          route_to_leader = LARHeaders.rollback
          opts = default_options session_name: session_name,
                                 call_options: call_options,
                                 route_to_leader: route_to_leader
          request = { session: session_name, transaction_id: transaction_id }
          service.rollback request, opts
        end

        def begin_transaction session_name,
                              exclude_txn_from_change_streams: false,
                              request_options: nil,
                              call_options: nil,
                              route_to_leader: nil
          tx_opts = V1::TransactionOptions.new(
            read_write: V1::TransactionOptions::ReadWrite.new,
            exclude_txn_from_change_streams: exclude_txn_from_change_streams
          )
          opts = default_options session_name: session_name,
                                 call_options: call_options,
                                 route_to_leader: route_to_leader
          request = {
            session: session_name,
            options: tx_opts,
            request_options: request_options
          }
          service.begin_transaction request, opts
        end

        def batch_write session_name,
                        mutation_groups,
                        exclude_txn_from_change_streams: false,
                        request_options: nil,
                        call_options: nil
          route_to_leader = LARHeaders.batch_write
          opts = default_options session_name: session_name,
                                 call_options: call_options,
                                 route_to_leader: route_to_leader
          request = {
            session: session_name,
            request_options: request_options,
            mutation_groups: mutation_groups,
            exclude_txn_from_change_streams: exclude_txn_from_change_streams
          }
          service.batch_write request, opts
        end

        def create_snapshot session_name, strong: nil, timestamp: nil,
                            staleness: nil, call_options: nil
          tx_opts = V1::TransactionOptions.new(
            read_only: V1::TransactionOptions::ReadOnly.new(
              {
                strong: strong,
                read_timestamp: Convert.time_to_timestamp(timestamp),
                exact_staleness: Convert.number_to_duration(staleness),
                return_read_timestamp: true
              }.compact
            )
          )
          opts = default_options session_name: session_name,
                                 call_options: call_options
          request = { session: session_name, options: tx_opts }
          service.begin_transaction request, opts
        end

        def create_pdml session_name,
                        exclude_txn_from_change_streams: false,
                        call_options: nil
          tx_opts = V1::TransactionOptions.new(
            partitioned_dml: V1::TransactionOptions::PartitionedDml.new,
            exclude_txn_from_change_streams: exclude_txn_from_change_streams
          )
          route_to_leader = LARHeaders.begin_transaction true
          opts = default_options session_name: session_name,
                                 call_options: call_options,
                                 route_to_leader: route_to_leader
          request = { session: session_name, options: tx_opts }
          service.begin_transaction request, opts
        end

        def create_backup instance_id, database_id, backup_id, expire_time,
                          version_time, call_options: nil,
                          encryption_config: nil
          opts = default_options call_options: call_options
          backup = {
            database: database_path(instance_id, database_id),
            expire_time: expire_time,
            version_time: version_time
          }
          request = {
            parent:    instance_path(instance_id),
            backup_id: backup_id,
            backup:    backup,
            encryption_config: encryption_config
          }
          databases.create_backup request, opts
        end

        def get_backup instance_id, backup_id, call_options: nil
          opts = default_options call_options: call_options
          request = { name: backup_path(instance_id, backup_id) }
          databases.get_backup request, opts
        end

        def update_backup backup, update_mask, call_options: nil
          opts = default_options call_options: call_options
          request = { backup: backup, update_mask: update_mask }
          databases.update_backup request, opts
        end

        def delete_backup instance_id, backup_id, call_options: nil
          opts = default_options call_options: call_options
          request = { name: backup_path(instance_id, backup_id) }
          databases.delete_backup request, opts
        end

        def list_backups instance_id,
                         filter: nil, page_size: nil, page_token: nil,
                         call_options: nil
          opts = default_options call_options: call_options
          request = {
            parent:    instance_path(instance_id),
            filter:    filter,
            page_size: page_size,
            page_token: page_token
          }
          databases.list_backups request, opts
        end

        def list_database_operations instance_id,
                                     filter: nil,
                                     page_size: nil,
                                     page_token: nil,
                                     call_options: nil
          opts = default_options call_options: call_options
          request = {
            parent:     instance_path(instance_id),
            filter:     filter,
            page_size:  page_size,
            page_token: page_token
          }
          databases.list_database_operations request, opts
        end

        def list_backup_operations instance_id,
                                   filter: nil, page_size: nil,
                                   page_token: nil,
                                   call_options: nil
          opts = default_options call_options: call_options
          request = {
            parent:     instance_path(instance_id),
            filter:     filter,
            page_size:  page_size,
            page_token: page_token
          }
          databases.list_backup_operations request, opts
        end

        def restore_database backup_instance_id, backup_id,
                             database_instance_id, database_id,
                             call_options: nil, encryption_config: nil
          opts = default_options call_options: call_options
          request = {
            parent:      instance_path(database_instance_id),
            database_id: database_id,
            backup:      backup_path(backup_instance_id, backup_id),
            encryption_config: encryption_config
          }
          databases.restore_database request, opts
        end

        ##
        # Checks if a request can be retried. This is based on the error returned.
        # Retryable errors are:
        #   - Unavailable error
        #   - Internal EOS error
        #   - Internal RST_STREAM error
        def retryable? err
          err.instance_of?(Google::Cloud::UnavailableError) ||
            err.instance_of?(GRPC::Unavailable) ||
            (err.instance_of?(Google::Cloud::InternalError) && err.message.include?(EOS_INTERNAL_ERROR)) ||
            (err.instance_of?(GRPC::Internal) && err.details.include?(EOS_INTERNAL_ERROR)) ||
            (err.instance_of?(Google::Cloud::InternalError) && err.message.include?(RST_STREAM_INTERNAL_ERROR)) ||
            (err.instance_of?(GRPC::Internal) && err.details.include?(RST_STREAM_INTERNAL_ERROR))
        end

        def inspect
          "#{self.class}(#{@project})"
        end

        protected

        def lib_name_with_prefix
          return "gccl" if [nil, "gccl"].include? lib_name

          value = lib_name.dup
          value << "/#{lib_version}" if lib_version
          value << " gccl"
        end

        def default_options session_name: nil, call_options: nil, route_to_leader: nil
          opts = {}
          metadata = {}
          if session_name
            default_prefix = session_name.split("/sessions/").first
            metadata["google-cloud-resource-prefix"] = default_prefix
          end
          if @enable_leader_aware_routing && !route_to_leader.nil?
            metadata["x-goog-spanner-route-to-leader"] = route_to_leader
          end
          opts[:metadata] = metadata
          if call_options
            opts[:timeout] = call_options[:timeout] if call_options[:timeout]
            opts[:retry_policy] = call_options[:retry_policy] if call_options[:retry_policy]
          end
          ::Gapic::CallOptions.new(**opts)
        end

        def partition_options partition_size_bytes, max_partitions
          return nil unless partition_size_bytes || max_partitions
          partition_opts = V1::PartitionOptions.new
          if partition_size_bytes
            partition_opts.partition_size_bytes = partition_size_bytes
          end
          partition_opts.max_partitions = max_partitions if max_partitions
          partition_opts
        end

        def project_path
          Admin::Instance::V1::InstanceAdmin::Paths.project_path \
            project: project
        end

        def instance_path name
          return name if name.to_s.include? "/"

          Admin::Instance::V1::InstanceAdmin::Paths.instance_path \
            project: project, instance: name
        end

        def instance_config_path name
          return name if name.to_s.include? "/"

          Admin::Instance::V1::InstanceAdmin::Paths.instance_config_path \
            project: project, instance_config: name
        end

        def database_path instance_id, database_id
          Admin::Database::V1::DatabaseAdmin::Paths.database_path \
            project: project, instance: instance_id, database: database_id
        end

        def session_path instance_id, database_id, session_id
          V1::Spanner::Paths.session_path \
            project: project, instance: instance_id, database: database_id,
            session: session_id
        end

        def backup_path instance_id, backup_id
          Admin::Database::V1::DatabaseAdmin::Paths.backup_path \
            project: project, instance: instance_id, backup: backup_id
        end
      end
    end
  end
end
