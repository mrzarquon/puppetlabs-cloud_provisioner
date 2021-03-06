require 'tempfile'
require 'rubygems'
require 'guid'
require 'fog'
require 'net/ssh'
require 'puppet/network/http_pool'
require 'puppet/cloudpack/progressbar'
require 'puppet/cloudpack/utils'
require 'timeout'

module Puppet::CloudPack
  class InstanceErrorState < Exception
  end

  # This is a utility class to provide access to the methods defined
  # in the +Net::HTTPHeader+ module (e.g. +set_content_type+,
  # +basic_auth+, etc.).
  # Additionally it overrides the +to_hash+ method to return a hash
  # of simple (+String+) values rather than a hash of +Array+s so that
  # the returned value is usable as input to +Net::HTTP.get+,
  # +Net::HTTP.post+ etc. family of methods (and consequently the
  # +Puppet::Network::HTTP::Connection.request+ method).
  class HttpHeaders
    include Net::HTTPHeader

    def initialize(headers = nil)
      initialize_http_header(headers)
    end

    def to_hash
      hash = {}
      each do |k, v|
        hash[k] = v
      end
      hash
    end
  end

  require 'puppet/cloudpack/installer'
  class << self

    def add_availability_zone_option(action)
      action.option '--availability-zone=' do
        summary 'AWS availability zone.'
        description <<-EOT
          Specifies the availability zone into which the VM will be created
        EOT
     end
    end
    def add_region_option(action)
      action.option '--region=' do
        summary "The geographic region of the instance. Defaults to us-east-1."
        description <<-'EOT'
          The instance may run in any region EC2 operates within.  The regions at the
          time of this documentation are: US East (Northern Virginia), US West (Northern
          California), EU (Ireland), Asia Pacific (Singapore), and Asia Pacific (Tokyo).

          The region names for this command are: eu-west-1, us-east-1,
          ap-northeast-1, us-west-1, ap-southeast-1

          Note: to use another region, you will need to copy your keypair and reconfigure the
          security groups to allow SSH access.
        EOT

        default_to { 'us-east-1' }

        before_action do |action, args, options|

          regions_response = Puppet::CloudPack.create_connection(options).describe_regions
          region_names = regions_response.body["regionInfo"].collect { |r| r["regionName"] }.flatten
          unless region_names.include?(options[:region])
            raise ArgumentError, "Region must be one of the following: #{region_names.join(', ')}"
          end
        end
      end
    end

    def add_credential_option(action)
      action.option '--credentials=' do
        summary 'Cloud credentials to use from ~/.fog'
        description <<-EOT
          For accessing more than a single account, auxiliary credentials other
          than 'default' may be supplied in the credentials location (usually
          ~/.fog).
        EOT
      end
    end

    # JJM This method is separated from the before_action block to aid testing.
    def group_option_before_action(options)
      if not options[:security_group].is_a? Array
        options[:security_group] = options[:security_group].split(File::PATH_SEPARATOR)
      end

      known_by_id = {}
      known_by_name = {}
      Puppet::CloudPack.create_connection(options).security_groups.each do |g|
        known_by_id[g.group_id] = g
        known_by_name[g.name] = g
      end
      known = {}
      unknown = []
      options[:security_group].each do |g|
        # look up the group by its ID first, if not found then by name
        if sg = known_by_id[g] || sg = known_by_name[g]
          # store the group_id as a key in a hash to eliminate duplicates
          known[sg.group_id] = known.size unless known.include?(sg.group_id)
        else
          unknown << g
        end
      end
      unless unknown.empty?
        raise ArgumentError, "Unrecognized security groups: #{unknown.join(', ')}"
      end
      # now rebuild the security_group option argument array from the 'known' hash
      # so that every group in the array is specified by its ID, there are no
      # duplicates and the order of the groups in the array is the same as the order
      # in which the groups were specified on the command line
      options[:security_group] = known.keys.sort { |l, r| known[l] <=> known[r] }
    end

    def add_create_options(action)
      add_region_option(action)
      add_availability_zone_option(action)
      add_tags_option(action)
      add_image_option(action)
      add_type_option(action)
      add_keyname_option(action)
      add_subnet_option(action)
      add_group_option(action)
    end

    def add_tags_option(action)
      action.option '--instance-tags=', '-t=' do
        summary 'The tags the instance should have in format tag1=value1,tag2=value2'
        description <<-EOT
          Instances may be tagged with custom tags. The tags should be in the
          format of tag1=value,tag2=value. Currently there is not way escape
          the ',' character so tags cannot contain this character.
        EOT

        before_action do |action, arguments, options|
          ## This converts 'this=that,foo=bar,biz=baz=also' to
          ## { 'this' => 'that', 'foo' => 'bar', 'biz' => 'baz=also'}
          ##
          ## A regex is needed that will allow us to escape ',' characters
          ## from the CLI
          begin
            options[:instance_tags] = Hash[ options[:instance_tags].split(',').map do |tag|
              tag_array = tag.split('=',2)
              if tag_array.size != 2
                raise ArgumentError, 'Could not parse tags given. Please check your format'
              end
              if [nil,''].include? tag_array[0] or [nil,''].include? tag_array[1]
                raise ArgumentError, 'Could not parse tags given. Please check your format'
              end
              tag_array
            end ]
          rescue
            raise ArgumentError, 'Could not parse tags given. Please check your format'
          end
        end

      end
    end

    def add_image_option(action)
      action.option '--image=', '-i=' do
        summary 'AMI to use when creating the instance.'
        description <<-EOT
          The pre-configured operating system image to use when creating this
          machine instance. Currently, only AMI images are supported. Example
          of a Redhat 5.6 32bit image: ami-b241bfdb
        EOT
        required
        before_action do |action, args, options|
          if Puppet::CloudPack.create_connection(options).images.get(options[:image]).nil?
            raise ArgumentError, "Unrecognized image name: #{options[:image]}"
          end
        end
      end
    end

    def add_type_option(action)
      action.option '--type=' do
        summary 'Type of instance.'
        description <<-EOT
          Type of instance to be launched. The type specifies characteristics that
          a machine will have, such as architecture, memory, processing power, storage,
          and IO performance. The type selected will determine the cost of a machine instance.

          All instance types available from EC2 are supported; see the EC2 documentation
          online at http://aws.amazon.com/ec2/instance-types/ for details.
        EOT
        required
      end
    end

    def add_keyname_option(action)
      action.option '--keyname=' do
        summary 'The AWS SSH key name as shown in the AWS console. See the list_keynames action.'
        description <<-EOT
          The name of the SSH key pair to use, as listed in the Amazon AWS
          console.  When creating the instance, Amazon will install the
          requested SSH public key into the instance's authorized_keys file.
          Not to be confused with the --keyfile option of the `node`
          subcommand's `install` action.

          You can use the `list_keynames` action to get a list of valid key
          pairs.
        EOT
        required
        before_action do |action, args, options|
          if Puppet::CloudPack.create_connection(options).key_pairs.get(options[:keyname]).nil?
            raise ArgumentError, "Unrecognized key name: #{options[:keyname]} (Suggestion: use the puppet node_aws list_keynames action to find a list of valid key names for your account.)"
          end
        end
      end
    end

    def add_subnet_option(action)
      action.option '--subnet=', '-s='  do
        summary "The subnet in which to deploy the VM (VPC only)"
        description <<-EOT
           This is the ID of the subnet in which you wish the vm to reside.
           This feature is only available when using EC2's VPC feature.
        EOT
      end
    end

    def add_group_option(action)
      action.option '--security-group=', '-g=' do
        summary "The instance's security group(s)."
        description <<-EOT
          The security group(s) that the machine will be associated with. A
          security group determines the rules for both inbound and outbound
          connections.

          Multiple groups can be specified as a colon-separated list. The
          groups can be specified by names or IDs.
        EOT
        before_action do |action, args, options|
          Puppet::CloudPack.group_option_before_action(options)
        end
      end
    end

    def add_list_options(action)
      add_region_option(action)
    end

    def add_list_keynames_options(action)
      add_region_option(action)
    end

    def add_fingerprint_options(action)
      add_region_option(action)
    end

    def add_init_options(action)
      add_install_options(action)
      add_classify_options(action)
    end

    def add_terminate_options(action)
      add_region_option(action)
      action.option '--force', '-f' do
        summary 'Forces termination of an instance.'
      end
    end

    def add_bootstrap_options(action)
      add_create_options(action)
      add_init_options(action)
    end

    def add_install_options(action)
      action.option '--facts=' do
        summary 'Set custom facts in format of fact1=value,fact2=value'
        description <<-'EOT'
          To install custom facts during install of a node, use the format
          fact1=value,fact2=value. Currently, there is no way to escape
          the ',' character so facts cannot contain this character.

          Requirements:
          For community installs of puppet, i.e. not Puppet Enterprise,
          the Puppet Labs' `stdlib` module will be required. It can be found
          at 'http://forge.puppetlabs.com/puppetlabs/stdlib' or installed
          with the command 'puppet-module install puppetlabs/stdlib'.

          For Puppet Enterprise installs, there are no extra requirements
          for this option to work
        EOT

        before_action do |action, arguments, options|
          ## This converts 'this=that,foo=bar,biz=baz=also' to
          ## { 'this' => 'that', 'foo' => 'barr', 'biz' => 'baz=also'}
          ##
          ## A regex is needed that will allow us to escape ',' characters
          ## from the CLI
          begin
            options[:facts] = Hash[ options[:facts].split(',').map do |fact|
              fact_array = fact.split('=',2)
              if fact_array.size != 2
                raise ArgumentError, 'Could not parse facts given. Please check your format'
              end
              if [nil,''].include? fact_array[0] or [nil,''].include? fact_array[1]
                raise ArgumentError, 'Could not parse facts given. Please check your format'
              end
              fact_array
            end ]
          rescue
            raise ArgumentError, 'Could not parse facts given. Please check your format'
          end
        end
      end

      action.option '--login=', '-l=', '--username=' do
        summary 'User to log in to the instance as.'
        description <<-EOT
          The name of the user Puppet should use when logging in to the node.
          This user should configured to allow passwordless access via the SSH
          key supplied in the --keyfile option.

          This is usually the root user.
        EOT
        required
      end

      action.option '--keyfile=' do
        summary "The path to a local SSH private key (or 'agent' if using an agent)."
        description <<-EOT
          The filesystem path to a local private key that can be used to SSH
          into the node. If the node was created with the `node_aws` `create`
          action, this should be the path to the private key file downloaded
          from the Amazon EC2 interface.

          Specify 'agent' if you have the key loaded in ssh-agent and
          available via the SSH_AUTH_SOCK variable.
        EOT
        required
        before_action do |action, arguments, options|
          # If the user specified --keyfile=agent, check for SSH_AUTH_SOCK
          if options[:keyfile].downcase == 'agent' then
            # Force the option value to lower case to make it easier to test
            # for 'agent' in all other sections of the code.
            options[:keyfile].downcase!
            # Check if the user actually has access to an Agent.
            if ! ENV['SSH_AUTH_SOCK'] then
              raise ArgumentError,
                "SSH_AUTH_SOCK environment variable is not set and you specified --keyfile agent.  Please check that ssh-agent is running correctly, and that SSH agent forwarding is not disabled."
            end
            # We break out of the before action block because we don't really
            # have anything else to do to support ssh agent authentication.
            break
          end

          keyfile = File.expand_path(options[:keyfile])
          unless test 'f', keyfile
            raise ArgumentError, "Could not find file '#{keyfile}'"
          end
          unless test 'r', keyfile
            raise ArgumentError, "Could not read from file '#{keyfile}'"
          end
        end
      end

      add_payload_options(action)
    end

    def add_payload_options(action)
      action.option '--installer-payload=' do
        summary 'The location of the gzipped Puppet Enterprise install tarball.'
        description <<-EOT
          Location of the Puppet Enterprise install tarball to be used for
          the installation. Can be a local file path or a URL. This option is
          only required if Puppet should be installed on the machine. The
          specified tarball must be gzipped.
          Note that the specified Puppet install tarball must support the
          platform of the node on which the tarball is to be installed.
          If you are unsure about the node platform, use the universal install
          tarball. But be warned: it is huge.
        EOT
        before_action do |action, arguments, options|
          type = Puppet::CloudPack.payload_type(options[:installer_payload])
          case type
          when :invalid
            raise ArgumentError, "Invalid input '#{options[:installer_payload]}' for option installer-payload, should be a URL or a file path"
          when :file_path
            options[:installer_payload] = File.expand_path(options[:installer_payload])
            unless test 'f', options[:installer_payload]
              raise ArgumentError, "Could not find file '#{options[:installer_payload]}'"
            end
            unless test 'r', options[:installer_payload]
              raise ArgumentError, "Could not read from file '#{options[:installer_payload]}'"
            end
          end
          unless(options[:installer_payload] =~ /(tgz|gz)$/)
            Puppet.warning("Option: intaller-payload expects a .tgz or .gz file")
          end
        end
      end

      action.option '--installer-answers=' do
        summary 'Answers file to be used for PE installation.'
        description <<-EOT
          Location of the answers file that should be copied to the machine
          to install Puppet Enterprise.
        EOT
        before_action do |action, arguments, options|
          options[:installer_answers] = File.expand_path(options[:installer_answers])
          unless test 'f', options[:installer_answers]
            raise ArgumentError, "Could not find file '#{options[:installer_answers]}'"
          end
          unless test 'r', options[:installer_answers]
            raise ArgumentError, "Could not read from file '#{options[:installer_answers]}'"
          end
        end
      end

      action.option '--puppetagent-certname=' do
        summary 'The puppet agent certificate name to configure on the target system.'
        description <<-EOT
          This option allows you to specify an optional puppet agent
          certificate name to configure on the target system.  This option
          applies to the puppet-enterprise and puppet-enterprise-http
          installer scripts.  If provided, this option will replace any
          puppet agent certificate name provided in the puppet enterprise
          answers file.  This certificate name will show up in the console (or
          Puppet Dashboard) when the agent checks in for the first time.
        EOT
      end

      action.option '--install-script=' do
        summary 'The script to use when installing Puppet.'
        description <<-EOT
          Name of the installer script template to use when installing Puppet.
          The current list of supported scripts is:
            #{Puppet::CloudPack::Installer.find_builtin_templates.sort.join("\n            ")}
        EOT
        default_to { 'puppet-enterprise' }
        before_action do |action, arguments, options|
          # Check that the we can find the install script template.
          Puppet::CloudPack::Installer.find_template(options[:install_script])

          # Check that we have all the necessary inputs depending on the
          # install script specified.
          if options[:install_script].start_with?('puppet-enterprise')
            if options[:install_script].length == 'puppet-enterprise'.length
              # The canonical PE install script ('puppet-enterprise') needs both:
              # the installer payload and an answers file.
              unless options[:installer_payload] and options[:installer_answers]
                raise ArgumentError, 'Must specify installer payload and answers file if install script is puppet-enterprise'
              end
            elsif options[:install_script]['puppet-enterprise'.length, 1] == '-'
              # Other PE install scripts (those starting with 'puppet-enterprise-'),
              # need an answers file.
              unless options[:installer_answers]
                raise ArgumentError, "Must specify an answers file for install script #{options[:install_script]}"
              end
            end
          end
        end
      end

      action.option '--puppet-version=' do
        summary 'Version of Puppet to install.'
        description <<-EOT
          Version of Puppet to be installed. This version is
          passed to the Puppet installer script.
        EOT
        before_action do |action, arguments, options|
          unless options[:puppet_version] =~ /^(\d+)\.(\d+)(\.(\d+|x))?$|^(\d)+\.(\d)+\.(\d+)([a-zA-Z][a-zA-Z0-9-]*)|master$/
            raise ArgumentError, "Invaid Puppet version '#{options[:puppet_version]}'"
          end
        end
      end

      action.option '--facter-version=' do
        summary 'Version of facter to install.'
        description <<-EOT
          The version of facter that should be installed.
          This only makes sense in open source installation
          mode.
        EOT
        before_action do |action, arguments, options|
          unless options[:facter_version] =~ /\d+\.\d+\.\d+/
            raise ArgumentError, "Invaid Facter version '#{options[:facter_version]}'"
          end
        end
      end
    end

    def add_classify_options(action)
      action.option '--enc-server=' do
        summary 'The external node classifier hostname.'
        description <<-EOT
          The hostname of the external node classifier.  This currently only
          supports Puppet Enterprise's console and Puppet Dashboard as external
          node classifiers.
        EOT
        default_to do
          Puppet[:server]
        end
      end

      action.option '--enc-port=' do
        summary 'The External Node Classifier Port.'
        description <<-EOT
          The port of the External Node Classifier.  This currently only
          supports Puppet Enterprise's console and Puppet Dashboard as external
          node classifiers.
        EOT
        default_to do 3000 end
      end

      action.option '--enc-auth-user=' do
        summary 'User name for authentication to the ENC.'
        description <<-EOT
          PE's console and Puppet Dashboard can be secured using HTTP
          authentication.  If the console or dashboard is configured with HTTP
          authentication, use this option to supply credentials for accessing it.

          Note: This option will default to the PUPPET_ENC_AUTH_USER
          environment variable.
        EOT
        default_to do ENV['PUPPET_ENC_AUTH_USER'] end
      end

      action.option '--enc-auth-passwd=' do
        summary 'Password for authentication to the ENC.'
        description <<-EOT
          PE's console and Puppet Dashboard can be secured using HTTP
          authentication.  If the console or dashboard is configured with HTTP
          authentication, use this option to supply credentials for accessing it.

          Note: This option will default to the PUPPET_ENC_AUTH_PASSWD
          environment variable.
        EOT
        default_to do ENV['PUPPET_ENC_AUTH_PASSWD'] end
      end

      action.option '--node-group=', '--as=' do
        summary 'The ENC node group to associate the node with.'
        description <<-'EOT'
          The PE console or Puppet Dashboard group to associate the node with.
          The group must already exist in the ENC, or an error will be
          returned.  If the node has not been registered with the ENC, it will
          automatically be registered when assigning it to a group.
        EOT
      end

      action.option '--insecure' do
        summary 'Don\'t perform ENC SSL certificate verification'
        description <<-'EOT'
          Don't verify the SSL certificate when connecting to an ENC.
          When connecting to the Puppet Enterprise Console, verification can be
          optionally skipped as older versions of the PE Console used to use
          certificates with a hardcoded Common Name which cannot be verified.
        EOT
        default_to { false }
      end
    end

    def bootstrap(options)
      server = self.create(options)
      self.init(server, options)
      return nil
    end

    def classify(certname, options)
      if options[:node_group]
        dashboard_classify(certname, options)
      else
        Puppet.notice('No classification method selected')
      end
    end

    def dashboard_classify(certname, options)
      # The Puppet::Network::HTTP::Connection instance
      http = Puppet::Network::HttpPool.http_instance(options[:enc_server], options[:enc_port], true, !options[:insecure])

      Puppet.notice "Contacting https://#{options[:enc_server]}:#{options[:enc_port]}/ to classify #{certname}"

      # This block create the node and returns it to the caller
      notfound_register_the_node = lambda do
        data = { 'node' => { 'name' => certname } }
        http_request(http, '/nodes.json', options, 'Register Node', '201', data)
      end
      # Get a list of nodes to check if we need to create the node or not
      nodes = http_request(http, '/nodes.json', options, 'List nodes')
      # Find an existing node or register the node using the lambda block
      node = nodes.find(notfound_register_the_node) do |node|
        node['name'] == certname
      end
      node_id = node['id']

      # checking if the specified group even exists
      notfound_group_dne_error = lambda do
        raise Puppet::Error, "Group #{options[:node_group]} does not exist in the console/Dashboard. Groups must exist before they can be assigned to nodes."
      end
      node_groups = http_request(http, '/node_groups.json', options, 'List Groups')
      node_group_info = node_groups.find(notfound_group_dne_error) do |group|
        group['name'] == options[:node_group]
      end
      node_group_id = node_group_info['id']

      # Finally add the node to the group.
      notfound_associate_node = lambda do
        data = { 'node_name' => certname, 'group_name' => options[:node_group] }
        http_request(http, '/memberships.json', options, 'Classify node', '201', data)
      end

      memberships = http_request(http, '/memberships.json', options, 'List group members')
      response = memberships.find(notfound_associate_node) do |members|
        members['node_group_id'] == node_group_id and members['node_id'] == node_id
      end

      return { 'status' => 'complete' }
    end

    def handle_json_response(response, action, expected_code='200')
      if response.code == expected_code
        Puppet.info "#{action} ... Done"
        PSON.parse response.body
      else
        # I should probably raise an exception!
        Puppet.warning "#{action} ... Failed"
        Puppet.info("Body: #{response.body}")
        Puppet.warning "Server responded with a #{response.code} status"
        case response.code
        when /401/
          Puppet.notice "A 401 response is the HTTP code for an Unauthorized request"
          Puppet.notice "This error likely means you need to supply the --enc-auth-user and --enc-auth-passwd options"
          Puppet.notice "Alternatively, use the PUPPET_ENC_AUTH_PASSWD environment variable"
        end
        raise Puppet::Error, "Could not: #{action}, got #{response.code} expected #{expected_code}"
      end
    end

    def create(options)
      unless options.has_key? :_destroy_server_at_exit
        options[:_destroy_server_at_exit] = :create
      end

      Puppet.info("Connecting to AWS #{options[:region]} ...")
      connection = create_connection(options)
      Puppet.info("Connecting to AWS #{options[:region]} ... Done")
      Puppet.info("Instance Type: #{options[:type]}")

      # TODO: Validate that the security groups permit SSH access from here.
      # TODO: Can this throw errors?
      server = create_server(connection.servers,
        :image_id           => options[:image],
        :key_name           => options[:keyname],
        :security_group_ids => options[:security_group],
        :flavor_id          => options[:type],
        :subnet_id          => options[:subnet],
        :availability_zone  => options[:availability_zone]
      )

      # This is the earliest point we have knowledge of the instance ID
      Puppet.info("Instance identifier: #{server.id}")

      Signal.trap(:EXIT) do
        if options[:_destroy_server_at_exit]
          server.destroy rescue nil
          Puppet.err("Destroyed server #{server.id} because of an abnormal exit")
        end
      end

      unless (options[:tags_not_supported])
        tags = {'Created-By' => 'Puppet'}
        tags.merge! options[:instance_tags] if options[:instance_tags]

        Puppet.notice('Creating tags for instance ... ')
        create_tags(connection.tags, server.id, tags)
        Puppet.notice('Creating tags for instance ... Done')
      end

      Puppet.notice("Launching server #{server.id} ...")
      retries = 0
      begin
        server.wait_for do
          print '#'
          raise Puppet::CloudPack::InstanceErrorState if self.state == 'error'
          self.ready?
        end
        puts
        Puppet.notice("Server #{server.id} is now launched")
      rescue Puppet::CloudPack::InstanceErrorState
        puts
        Puppet.err "Launching machine instance #{server.id} Failed."
        Puppet.err "Instance has entered an error state"
        return nil
      rescue Fog::Errors::Error
        Puppet.err "Launching server #{server.id} Failed."
        Puppet.err "Could not connect to host"
        Puppet.err "Please check your network connection and try again"
        return nil
      end

      # This is the earliest point we have knowledge of the DNS name
      Puppet.notice("Server #{server.id} public dns name: #{server.dns_name}")

      if options[:_destroy_server_at_exit] == :create
        options.delete(:_destroy_server_at_exit)
      end

      return server.dns_name
    end

    def list_keynames(options = {})
      connection = create_connection(options)
      keys_array = connection.key_pairs.collect do |key|
        key.attributes.inject({}) { |memo,(k,v)| memo[k.to_s] = v; memo }
      end
      # Covert the array into a Hash
      keys_hash = Hash.new
      keys_array.each { |key| keys_hash.merge!({key['name'] => key['fingerprint']}) }
      # Get a sorted list of the names
      sorted_names = keys_hash.keys.sort
      sorted_names.collect do |name|
        { 'name' => name, 'fingerprint' => keys_hash[name] }
      end
    end

    def list(options)
      connection = create_connection(options)
      servers = connection.servers
      # Convert the Fog object into a simple hash.
      # And return the array to the Faces API for rendering
      hsh = {}
      servers.each do |s|
        hsh[s.id] = {
          "id"         => s.id,
          "state"      => s.state,
          "keyname"    => s.key_name,
          "dns_name"   => s.dns_name,
          "created_at" => s.created_at,
          "tags"       => s.tags.inspect
        }
      end
      hsh
    end

    def fingerprint(server, options)
      connection = create_connection(options)
      servers = connection.servers.all('dns-name' => server)

      # Our hash for output.  We'll collect into this data structure.
      output_hash = {}
      output_array = servers.collect do |myserver|
        # TODO: Find a better way of getting the Fingerprints
        # The current method scrapes the AWS console looking for an ^ec2: pattern
        # This is not robust or ideal.  We make a "best effort" to find the fingerprint
        begin
          # Is there any console output yet?
          if myserver.console_output.body['output'].nil? then
            Puppet.info("Waiting for instance console output to become available ...")
            Fog.wait_for do
              print "#"
              not myserver.console_output.body['output'].nil?
            end or raise Fog::Errors::Error, "Waiting for console output timed out"
            puts "# Console output is ready"
          end
          # FIXME Where is the fingerprint?  Do we output it ever?
          { "#{myserver.id}" => myserver.console_output.body['output'].grep(/^ec2:/) }
        rescue Fog::Errors::Error => e
          Puppet.warning "Waiting for SSH host key fingerprint from AWS ... Failed"
          Puppet.warning "Could not read the host's fingerprints"
          Puppet.warning "Please verify the host's fingerprints through the AWS console output"
        end
      end
      output_array.each { |hsh| output_hash = hsh.merge(output_hash) }
      # Check to see if we got anything back
      if output_hash.collect { |k,v| v }.flatten.empty? then
        Puppet.warning "We could not securely find a fingerprint because the image did not print the fingerprint to the console."
        Puppet.warning "Please use an AMI that prints the fingerprint to the console in order to connect to the instance more securely."
        Puppet.info "The system is ready.  Please add the host key to your known hosts file."
        Puppet.info "For example: ssh root@#{server} and respond yes."
      end
      output_hash
    end

    def init(server, options)
      install_status = install(server, options)
      certname = install_status['puppetagent_certname']
      options.delete(:_destroy_server_at_exit)

      Puppet.notice "Puppet is now installed on: #{server}"

      classify(certname, options)

      # HACK: This should be reconciled with the Certificate Face.
      cert_options = {:ca_location => :remote}

      # TODO: Wait for C.S.R.?

      Puppet.notice "Signing certificate ..."
      begin
        Puppet::Face[:certificate, '0.0.1'].sign(certname, cert_options)
        Puppet.notice "Signing certificate ... Done"
      rescue Puppet::Error => e
        # TODO: Write useful next steps.
        Puppet.err "Signing certificate ... Failed"
        Puppet.err "Signing certificate error: #{e}"
        exit(1)
      rescue Net::HTTPError => e
        # TODO: Write useful next steps
        Puppet.warning "Signing certificate ... Failed"
        Puppet.err "Signing certificate error: #{e}"
        exit(1)
      end
    end

    def install(server, options)

      # If the end user wants to use their agent, we need to set keyfile to nil
      if options[:keyfile] == 'agent' then
        options[:keyfile] = nil
      end

      #Figure out our puppetagent-certname value
      if not options[:puppetagent_certname]
        options[:puppetagent_certname] = "#{server}-#{Guid.new.to_s}"
        options[:autogenerated_certname] = true
      end

      # Figure out if we need to be root
      cmd_prefix = options[:login] == 'root' ? '' : 'sudo '

      # FIXME: This appears to be an AWS assumption.  What about VMware with a plain IP?
      # (Not necessarily a bug, just a yak to shave...)
      options[:public_dns_name] = server

      # FIXME We shouldn't try to connect if the answers file hasn't been provided
      # for the installer script matching puppet-enterprise-* (e.g. puppet-enterprise-s3)
      connections = ssh_connect(server, options[:login], options[:keyfile])

      options[:tmp_dir] = File.join('/', 'tmp', Guid.new.to_s)
      create_tmpdir_cmd = "bash -c 'umask 077; mkdir #{options[:tmp_dir]}'"
      ssh_remote_execute(server, options[:login], create_tmpdir_cmd, options[:keyfile])

      upload_payloads(connections[:scp], options)

      tmp_script_tempfile = compile_template(options)
      remote_script_path = File.join(options[:tmp_dir], "#{options[:install_script]}.sh")
      connections[:scp].upload(tmp_script_tempfile.path, remote_script_path)
      # don't let the temporary file linger around
      tmp_script_tempfile.unlink
      tmp_script_tempfile = nil

      # Finally, execute the installer script
      install_command = "#{cmd_prefix}bash -c 'chmod u+x #{remote_script_path}; #{remote_script_path}'"
      results = ssh_remote_execute(server, options[:login], install_command, options[:keyfile])
      if results[:exit_code] != 0 then
        raise Puppet::Error, "The installer script exited with a non-zero exit status, indicating a failure.  It may help to run with --debug to see the script execution or to check the installation log file on the remote system in #{options[:tmp_dir]}."
      end

      # At this point we may assume installation of Puppet succeeded since the
      # install script returned with a zero exit code.

      # Determine the certificate name as reported by the remote system.
      certname_command = "#{cmd_prefix}puppet agent --configprint certname"
      results = ssh_remote_execute(server, options[:login], certname_command, options[:keyfile])

      if results[:exit_code] == 0 then
        puppetagent_certname = results[:stdout].strip
      else
        Puppet.warning "Could not determine the remote puppet agent certificate name using #{certname_command}"
        puppetagent_certname = nil
      end

      # Return value
      {
        'status'               => 'success',
        'puppetagent_certname' => puppetagent_certname,
        'stdout'               => results[:stdout],
      }
    end

    # This is the single place to make SSH calls.  It will handle collecting STDOUT
    # in a line oriented manner, printing it to debug log destination and checking the
    # exit code of the remote call.  This should also make it much easier to do unit testing on
    # all of the other methods that need this functionality.  Finally, it should provide
    # one place to swap out the back end SSH implementation if need be.
    def ssh_remote_execute(server, login, command, keyfile = nil)
      Puppet.info "Executing remote command ..."
      Puppet.debug "Command: #{command}"
      buffer = String.new
      stdout = String.new
      exit_code = nil
      # Figure out the options we need to pass to start.  This allows us to use SSH_AUTH_SOCK
      # if the end user specifies --keyfile=agent
      ssh_opts = keyfile ? { :keys => [ keyfile ] } : { }
      # Start
      begin
        Net::SSH.start(server, login, ssh_opts) do |session|
          session.open_channel do |channel|
            channel.request_pty
            channel.on_data do |ch, data|
              buffer << data
              stdout << data
              if buffer =~ /\n/
                lines = buffer.split("\n")
                buffer = lines.length > 1 ? lines.pop : String.new
                lines.each do |line|
                  Puppet.debug(line)
                end
              end
            end
            channel.on_eof do |ch|
              # Display anything remaining in the buffer
              unless buffer.empty?
                Puppet.debug(buffer)
              end
            end
            channel.on_request("exit-status") do |ch, data|
              exit_code = data.read_long
              Puppet.debug("SSH Command Exit Code: #{exit_code}")
            end
            # Finally execute the command
            channel.exec(command)
          end
        end
      rescue Net::SSH::AuthenticationFailed => user
        raise Net::SSH::AuthenticationFailed, "Authentication failure for user #{user}. Please check the keyfile and try again."
      end

      Puppet.info "Executing remote command ... Done"
      { :exit_code => exit_code, :stdout => stdout }
    end

    def ssh_test_connect(server, login, keyfile = nil)
      Puppet.notice "Waiting for SSH response ..."

      retry_exceptions = {
          Net::SSH::AuthenticationFailed => "Failed to connect. This may be because the machine is booting.\nRetrying the connection...",
          Errno::EHOSTUNREACH            => "Failed to connect. This may be because the machine is booting.  Retrying the connection..",
          Errno::ECONNREFUSED            => "Failed to connect. This may be because the machine is booting.  Retrying the connection...",
          Errno::ETIMEDOUT               => "Failed to connect. This may be because the machine is booting.  Retrying the connection..",
          Errno::ECONNRESET              => "Connection reset. Retrying the connection...",
          Timeout::Error                 => "Connection test timed-out. This may be because the machine is booting.  Retrying the connection...",
          Errno::ENETUNREACH             => "Network unreachable.  Retrying the connection...",
      }

      begin
        Puppet::CloudPack::Utils.retry_action( :timeout => 250, :retry_exceptions => retry_exceptions ) do
          Timeout::timeout(25) do
            ssh_remote_execute(server, login, "date", keyfile)
          end
        end
      rescue Utils::RetryException::Timeout
        Puppet.notice "Waiting for SSH response ... Timeout"
        raise Puppet::CloudPack::InstanceErrorState, "Timeout while establishing SSH connection to: #{server}"
      end

      Puppet.notice "Waiting for SSH response ... Done"
      true
    end

    def ssh_connect(server, login, keyfile = nil)
      opts = {}
      # This allows SSH_AUTH_SOCK agent usage if keyfile is nil
      opts[:key_data] = [File.read(File.expand_path(keyfile))] if keyfile

      ssh_test_connect(server, login, keyfile)

      ssh = Fog::SSH.new(server, login, opts)
      scp = Fog::SCP.new(server, login, opts)

      {:ssh => ssh, :scp => scp}
    end

    def upload_payloads(scp, options)
      if options[:installer_payload] and payload_type(options[:installer_payload]) == :file_path
        Puppet.notice "Uploading Puppet Enterprise tarball ..."
        scp.upload(options[:installer_payload], "#{options[:tmp_dir]}/puppet.tar.gz")
        Puppet.notice "Uploading Puppet Enterprise tarball ... Done"
      end

      if options[:installer_answers]
        Puppet.info "Uploading Puppet Answer File ..."
        scp.upload(options[:installer_answers], "#{options[:tmp_dir]}/puppet.answers")
        Puppet.info "Uploading Puppet Answer File ... Done"
      end
    end

    def compile_template(options)
      Puppet.notice "Installing Puppet ..."
      options[:server] = Puppet[:server]
      options[:environment] = Puppet[:environment] || 'production'

      install_script = Puppet::CloudPack::Installer.build_installer_template(options[:install_script], options)
      Puppet.debug("Compiled installer script:")
      Puppet.debug(install_script)

      # create a tempfile and write the compiled script to it
      # return the temfile instance
      f = Tempfile.open('install_script')
      f.write(install_script)
      f.close
      f
    end

    def terminate(server, options)
      # set the default id used for termination to dns_name
      options[:terminate_id] ||= 'dns-name'

      Puppet.info "Connecting to AWS ..."
      connection = create_connection(options)
      Puppet.info "Connecting to AWS ... Done"

      servers = connection.servers.all(options[:terminate_id] => server)
      if servers.length == 1 || options[:force]
        # We're using myserver rather than server to prevent ruby 1.8 from
        # overwriting the server method argument
        servers.each do |myserver|
          Puppet.notice "Destroying #{myserver.id} (#{myserver.dns_name}) ..."
          myserver.destroy()
          Puppet.notice "Destroying #{myserver.id} (#{myserver.dns_name}) ... Done"
        end
      elsif servers.empty?
        Puppet.warning "Could not find server with DNS name '#{server}'"
      else
        Puppet.err "More than one server with DNS name '#{server}'; aborting"
      end

      return nil
    end

    def create_connection(options = {})
      # We don't support more than AWS, but this satisfies the rspec tests
      # that pass in a provider string that does not match 'AWS'.  This makes
      # the test pass by preventing Fog from throwing an error when the region
      # option is not expected
      Fog.credential = options[:credentials].to_sym if options[:credentials]
      # fog is smart enough to pass options that are set to nil
      Fog::Compute.new(
        :provider => 'AWS',
        :region => options[:region],
        :endpoint => options[:endpoint]
      )
    end

    def create_server(servers, options = {})
      Puppet.notice('Creating new instance ...')
      server = servers.create(options)
      Puppet.notice("Creating new instance ... Done")
      return server
    end

    def create_tags(t_connection, resource_id, tags)
      raise(ArgumentError, 'tags must be a hash') unless tags.is_a? Hash

        tags.each do |tag,value|
          Puppet.info("Creating tag for #{tag} ... ")
          Puppet::CloudPack::Utils.retry_action( :timeout => 120 ) do
            t_connection.create(
              :key         => tag,
              :value       => value,
              :resource_id => resource_id
            )
          end
        Puppet.info("Creating tag for #{tag} ... Done")
      end
    end

    def payload_type(payload)
      uri = begin
        URI.parse(payload)
      rescue URI::InvalidURIError => e
        return :invalid
      end
      if uri.class.to_s =~ /URI::(FTP|HTTPS?)/
        $1.downcase.to_sym
      else
        # assuming that everything else is a valid filepath
        :file_path
      end
    end

    # Method to make generic, SSL, Authenticated HTTP requests
    # and parse the JSON response.  Primarily for #10377 and #10197
    def http_request(http, path, options = {}, action = nil, expected_code = '200', data = nil)
      headers = HttpHeaders.new
      # Authentication information
      headers.basic_auth(options[:enc_auth_user], options[:enc_auth_passwd]) unless options[:enc_auth_user].nil?
      # Content Type of the request
      headers.set_content_type('application/json')
      # Convert the headers to a plain hash
      headers = headers.to_hash

      # Prepare the arguments of the request call
      args = data.nil? \
        ? [:get, path, headers] \
        : [:post, path, data.to_pson, headers]

      # Wrap the request in an exception handler
      begin
        response = http.request(*args)
      rescue Errno::ECONNREFUSED => e
        Puppet.warning 'Registering node ... Error'
        Puppet.err "Could not connect to host #{options[:enc_server]} on port #{options[:enc_port]}"
        Puppet.err "This could be because a local host firewall is blocking the connection"
        Puppet.err "Please check your --enc-server and --enc-port options"
        ex = Puppet::Error.new(e)
        ex.set_backtrace(e.backtrace)
        raise ex
      end
      # Return the parsed JSON response
      handle_json_response(response, action || path, expected_code)
    end

    # Take a block and a timeout and display a progress bar while we're doing our thing
    def do_in_progress_bar(options = {}, &blk)
      timeout = options[:timeout].to_i
      start_time = Time.now
      abort_time = start_time + timeout

      Puppet.notice "#{options[:notice]} (Started at #{start_time.strftime("%I:%M:%S %p")})"
      eta_msg = if (timeout <= 120) then
                  "#{timeout} seconds at #{abort_time.strftime("%I:%M:%S %p")}"
                else
                  "#{timeout / 60} minutes at #{abort_time.strftime("%I:%M %p")}"
                end
      Puppet.notice "Control will be returned to you in #{eta_msg} if #{options[:message].downcase} is unfinished."

      progress_bar = Puppet::CloudPack::ProgressBar.new(options[:message], timeout)
      progress_mutex = Mutex.new

      progress_thread = Thread.new do
        loop do
          progress = Time.now - start_time
          progress_mutex.synchronize { progress_bar.set progress }
          sleep 0.5
        end
      end

      block_return_value = nil
      begin
        Timeout.timeout(timeout) do
          block_return_value = blk.call
        end
      ensure
        progress_mutex.synchronize { progress_bar.finish; progress_thread.kill }
      end
      end_time = Time.now
      block_return_value
    end
  end
end
