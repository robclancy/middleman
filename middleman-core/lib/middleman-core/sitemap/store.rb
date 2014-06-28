# Used for merging results of metadata callbacks
require 'active_support/core_ext/hash/deep_merge'
require 'monitor'

# Extensions
require 'middleman-core/sitemap/extensions/on_disk'
require 'middleman-core/sitemap/extensions/redirects'
require 'middleman-core/sitemap/extensions/request_endpoints'
require 'middleman-core/sitemap/extensions/proxies'
require 'middleman-core/sitemap/extensions/ignores'

module Middleman
  # Sitemap namespace
  module Sitemap
    # The Store class
    #
    # The Store manages a collection of Resource objects, which represent
    # individual items in the sitemap. Resources are indexed by "source path",
    # which is the path relative to the source directory, minus any template
    # extensions. All "path" parameters used in this class are source paths.
    class Store
      # @return [Middleman::Application]
      attr_reader :app

      attr_reader :update_count

      # Initialize with parent app
      # @param [Middleman::Application] app
      def initialize(app)
        @app = app
        @resources = []
        @update_count = 0;

        # TODO: Should this be a set or hash?
        @resource_list_manipulators = []
        @needs_sitemap_rebuild = true

        @lock = Monitor.new
        reset_lookup_cache!

        # Handle ignore commands
        Middleman::Sitemap::Extensions::Ignores.new(@app, self)

        # Extensions
        {
          # Register classes which can manipulate the main site map list
          on_disk: Middleman::Sitemap::Extensions::OnDisk.new(@app, self),

          # Request Endpoints
          request_endpoints: Middleman::Sitemap::Extensions::RequestEndpoints.new(@app),

          # Proxies
          proxies: Middleman::Sitemap::Extensions::Proxies.new(@app),

          # Redirects
          redirects: Middleman::Sitemap::Extensions::Redirects.new(@app)
        }.each do |k, m|
          register_resource_list_manipulator(k, m)
        end

        @app.config_context.class.send :delegate, :sitemap, to: :app
      end

      # Register an object which can transform the sitemap resource list. Best to register
      # these in a `before_configuration` or `after_configuration` hook.
      #
      # @param [Symbol] name Name of the manipulator for debugging
      # @param [#manipulate_resource_list] manipulator Resource list manipulator
      # @param [Numeric] priority Sets the order of this resource list manipulator relative to the rest. By default this is 50, and manipulators run in the order they are registered, but if a priority is provided then this will run ahead of or behind other manipulators.
      # @return [void]
      def register_resource_list_manipulator(name, manipulator, priority=50)
        # The third argument used to be a boolean - handle those who still pass one
        priority = 50 unless priority.is_a? Numeric
        @resource_list_manipulators << [name, manipulator, priority]
        # The index trick is used so that the sort is stable - manipulators with the same priority
        # will always be ordered in the same order as they were registered.
        n = 0
        @resource_list_manipulators = @resource_list_manipulators.sort_by do |m|
          n += 1
          [m[2], n]
        end
        rebuild_resource_list!(:registered_new)
      end

      # Rebuild the list of resources from scratch, using registed manipulators
      # @return [void]
      def rebuild_resource_list!(_=nil)
        @lock.synchronize do
          @needs_sitemap_rebuild = true
        end
      end

      # Find a resource given its original path
      # @param [String] request_path The original path of a resource.
      # @return [Middleman::Sitemap::Resource]
      def find_resource_by_path(request_path)
        @lock.synchronize do
          request_path = ::Middleman::Util.normalize_path(request_path)
          ensure_resource_list_updated!
          @_lookup_by_path[request_path]
        end
      end

      # Find a resource given its destination path
      # @param [String] request_path The destination (output) path of a resource.
      # @return [Middleman::Sitemap::Resource]
      def find_resource_by_destination_path(request_path)
        @lock.synchronize do
          request_path = ::Middleman::Util.normalize_path(request_path)
          ensure_resource_list_updated!
          @_lookup_by_destination_path[request_path]
        end
      end

      # Get the array of all resources
      # @param [Boolean] include_ignored Whether to include ignored resources
      # @return [Array<Middleman::Sitemap::Resource>]
      def resources(include_ignored=false)
        @lock.synchronize do
          ensure_resource_list_updated!
          if include_ignored
            @resources
          else
            @resources_not_ignored ||= @resources.reject(&:ignored?)
          end
        end
      end

      # Invalidate our cached view of resource that are not ingnored. If your extension
      # adds ways to ignore files, you should call this to make sure #resources works right.
      def invalidate_resources_not_ignored_cache!
        @resources_not_ignored = nil
      end

      # Get the URL path for an on-disk file
      # @param [String] file
      # @return [String]
      def file_to_path(file)
        file = File.join(@app.root, file)

        prefix = @app.source_dir.sub(/\/$/, '') + '/'
        return false unless file.start_with?(prefix)

        path = file.sub(prefix, '')

        # Replace a file name containing automatic_directory_matcher with a folder
        unless @app.config[:automatic_directory_matcher].nil?
          path = path.gsub(@app.config[:automatic_directory_matcher], '/')
        end

        extensionless_path(path)
      end

      # Get a path without templating extensions
      # @param [String] file
      # @return [String]
      def extensionless_path(file)
        path = file.dup
        remove_templating_extensions(path)
      end

      # Actually update the resource list, assuming anything has called
      # rebuild_resource_list! since the last time it was run. This is
      # very expensive!
      def ensure_resource_list_updated!
        @lock.synchronize do
          return unless @needs_sitemap_rebuild
          @needs_sitemap_rebuild = false

          @app.logger.debug '== Rebuilding resource list'

          @resources = @resource_list_manipulators.reduce([]) do |result, (_, manipulator, _)|
            newres = manipulator.manipulate_resource_list(result)

            # Reset lookup cache
            reset_lookup_cache!
            newres.each do |resource|
              @_lookup_by_path[resource.path] = resource
              @_lookup_by_destination_path[resource.destination_path] = resource
            end

            newres
          end

          invalidate_resources_not_ignored_cache!
          @update_count += 1
        end
      end

      private

      def reset_lookup_cache!
        @lock.synchronize {
          @_lookup_by_path = {}
          @_lookup_by_destination_path = {}
        }
      end

      # Removes the templating extensions, while keeping the others
      # @param [String] path
      # @return [String]
      def remove_templating_extensions(path)
        # Strip templating extensions as long as Tilt knows them
        path = path.sub(File.extname(path), '') while ::Tilt[path]
        path
      end

      # Remove the locale token from the end of the path
      # @param [String] path
      # @return [String]
      def strip_away_locale(path)
        if @app.respond_to? :langs
          path_bits = path.split('.')
          lang = path_bits.last
          return path_bits[0..-2].join('.') if @app.langs.include?(lang.to_sym)
        end

        path
      end
    end
  end
end
