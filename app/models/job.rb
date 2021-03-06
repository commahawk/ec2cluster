class Job < ActiveRecord::Base
  has_many :nodes
                              
  include AASM
  
  ######## Set Defaults ##################
  # see http://www.jroller.com/obie/entry/default_values_for_activerecord_attributes
  
  # The default setting is for the cluster to shut itself down when the job completes
  # but this is set in the database schema...
  
  # Use default base 32 bit Ubuntu amis
  # see http://alestic.com/ for details
  def master_ami_id
    self[:master_ami_id] or APP_CONFIG['default_master_ami_id']
  end
  
  def worker_ami_id
    self[:worker_ami_id] or APP_CONFIG['default_worker_ami_id']
  end  
  
  def instance_type
    self[:instance_type] or APP_CONFIG['default_instance_type']
  end  
  
  def availability_zone
    self[:availability_zone] or APP_CONFIG['default_availability_zone']
  end
  
  def mpi_version
    self[:mpi_version] or APP_CONFIG['default_mpi_version']
  end  
  
  def keypair
    self[:keypair] or APP_CONFIG['default_keypair']
  end    
  
  # TODO: add in User model, then pass in value here
  def user_id
    self[:user_id] or APP_CONFIG['default_user_id']
  end  
  
  ### Protected fields ##########
  # autopopulated by rails
  attr_protected :created_at, :updated_at
  
  # populated by job model itself (in state_machine blocks)
  attr_protected :mpi_service_rest_url, :started_at, :finished_at, :cancelled_at, :failed_at
  
  # populated by ClusterJob worker daemon
  attr_protected :master_security_group, :worker_security_group
  attr_protected :master_instance_id, :master_hostname, :master_public_hostname
    
    
  #### Validations ##############  
  # These should at least be present (log_path, keypair, EBS vols are optional)
  validates_presence_of :name, :description, :commands, :input_files, :output_files, :output_path
  validates_numericality_of :number_of_instances
  # these should be in the set of valid Amazon EC2 instance types...
  validates_inclusion_of :instance_type, :in => %w( m1.small m1.large m1.xlarge c1.medium c1.xlarge), :message => "instance type {{value}} is not an allowed EC2 instance type, must be in: m1.small m1.large m1.xlarge c1.medium c1.xlarge"
  validate :number_of_instances_must_be_at_least_1
  # TODO, these vary by EC2 account, check set using right_aws
  validates_inclusion_of :availability_zone, :in => %w( us-east-1a us-east-1b us-east-1c), :message => "availability zone {{value}} is not an allowed EC2 availability zone, must be in: us-east-1a us-east-1b us-east-1c"  
  # TODO- make this a check against EC2 api describe-images with right_aws
  validates_format_of [:worker_ami_id, :master_ami_id], 
                      :with => %r{^ami-}i,
                      :message => 'must be a valid Amazon EC2 AMI'
                     
  ####  Acts_as_state_machine transitions ############
                       
  aasm_column :state
  aasm_initial_state :pending
  aasm_state :pending
  aasm_state :launch_pending     
  aasm_state :launching_instances
  aasm_state :waiting_for_nodes
  aasm_state :exporting_master_nfs
  aasm_state :mounting_nfs
  aasm_state :configuring_cluster
  aasm_state :waiting_for_jobs
  aasm_state :running_job, :enter => :set_start_time # instances launched
  
  aasm_state :shutdown_requested, :enter => :terminate_cluster_later
  aasm_state :shutting_down_instances
  aasm_state :complete, :enter => :set_finish_time #instances terminated
  
  aasm_state :cancellation_requested, :enter => :terminate_cluster_later
  aasm_state :cancelling_job
  aasm_state :cancelled, :enter => :set_cancelled_time #instances terminated
  
  aasm_state :termination_requested, :enter => :terminate_cluster_later
  aasm_state :terminating_job     
  aasm_state :failed, :enter => :set_failed_time #instances terminated
  
  aasm_event :nextstep do
    transitions :to => :launch_pending, :from => [:pending]     
    transitions :to => :launching_instances, :from => [:launch_pending] 
     
    transitions :to => :waiting_for_nodes, :from => [:launching_instances]
    transitions :to => :exporting_master_nfs, :from => [:waiting_for_nodes]      
    transitions :to => :mounting_nfs, :from => [:exporting_master_nfs]       
    transitions :to => :configuring_cluster, :from => [:mounting_nfs] 
    transitions :to => :running_job, :from => [:configuring_cluster]
    transitions :to => :running_job, :from => [:waiting_for_jobs]
    transitions :to => :shutdown_requested, :from => [:running_job]  
      
    transitions :to => :shutting_down_instances, :from => [:shutdown_requested]
    transitions :to => :complete, :from => [:shutting_down_instances]
    
    transitions :to => :cancelling_job, :from => [:cancellation_requested]
    transitions :to => :cancelled, :from => [:cancelling_job]    
    
    transitions :to => :terminating_job, :from => [:termination_requested] 
    transitions :to => :failed, :from => [:terminating_job] 
  end  
  
  # TODO: provide a way to submit additional jobs/commands to a waiting cluster... 
  aasm_event :wait do
    transitions :to => :waiting_for_jobs, :from => [:running_job]
  end  
  
  aasm_event :cancel do
    transitions :to => :cancellation_requested, 
    :from => [
      :waiting_for_nodes,
      :exporting_master_nfs,
      :mounting_nfs,
      :configuring_cluster, 
      :running_job, 
      :waiting_for_jobs
    ]
  end  
    
  aasm_event :error do
    transitions :to => :termination_requested, 
    :from => [
      :pending,
      :launch_pending, 
      :launching_instances,
      :waiting_for_nodes,
      :exporting_master_nfs,
      :mounting_nfs,
      :configuring_cluster, 
      :running_job,
      :waiting_for_jobs,
      :shutdown_requested,
      :shutting_down_instances,
      :cancellation_requested,
      :cancelling_job,
      :cancelled,
      :termination_requested,
      :terminating_job
    ]
  end  


  ###### Model Methods ##########

  def initialize_job_parameters
    self.set_rest_url
    self.set_security_groups
  end
  
  def spinner_state
    if self.state.match('failed|cancelled|complete') 
      return "white.gif"
    else 
      return "spinner.gif"
    end    
  end
  
  

  def is_cancellable?
    cancellable_states = [
      "waiting_for_nodes",
      "configuring_cluster",
      "waiting_for_jobs",
      "running_job"
      ]
    return cancellable_states.include? self.state 
  end

  def processors_per_node
    # TODO: create a seperate model to hold this info
    cpus = {"m1.small"=>1, "m1.large"=>2, 
      "m1.xlarge"=>4, "c1.medium"=>2, "c1.xlarge"=>8}
    return cpus[self.instance_type]
  end



  def launch_cluster
    #TODO: add a check before each step to see if job has been cancelled, if so abort...
    puts 'background cluster launch initiated...' 
    begin      
      self.nextstep! # launch_pending -> launching_instances   
      @ec2 = RightAws::Ec2.new(APP_CONFIG['aws_access_key_id'],
                                  APP_CONFIG['aws_secret_access_key'])
 
      puts "Creating master security group"
      @ec2.create_security_group(self.master_security_group,'ec2cluster-Master-Node')
    
      self.set_progress_message("launching master node")     
      template = "/../views/jobs/bootstrap.sh.erb"
      bootscript_content = ERB.new(File.read(File.dirname(__FILE__)+template)).result(binding)  

      @masternode = boot_nodes(nodecount=1, ami=self.master_ami_id,
       security_group=self.master_security_group, bootscript=bootscript_content)      
      self.set_master_instance_metadata(@masternode[0])  
      puts "Master node booting"      
      if self.number_of_instances > 1
        puts "Launching worker nodes"   
        self.set_progress_message("launching worker nodes")
        @ec2.create_security_group(self.worker_security_group,'ec2cluster-Worker-Node')    
        @workernodes = boot_nodes(self.number_of_instances, self.worker_ami_id,
         self.worker_security_group, bootscript)              
      end
  
      self.set_progress_message("configuring nodes")      
      self.nextstep!  # launching_instances -> waiting_for_nodes
      puts "All nodes booted successfully, configuring nodes"       
    rescue Exception 
      self.error! # launching_instances -> terminating_due_to_error
      raise
    end
  end
  
  
  def boot_nodes(nodecount, ami, security_group, bootscript)
    # nodes could be running or pending...
    # running_nodes = self.nodes.find(:all, :conditions => {:aws_state => "running"})
    launching_nodes = self.nodes.find(:all, :conditions => "aws_state = 'pending' OR aws_state = 'running'")
    number_to_start = nodecount - launching_nodes.size
     
    node_descriptions = @ec2.run_instances(image_id=self.worker_ami_id, min_count=number_to_start,
          max_count=number_to_start, group_ids=[APP_CONFIG['web_security_group'], security_group],
          key_name=self.keypair,user_data=bootscript, addressing_type = 'public', 
          instance_type = self.instance_type, kernel_id = nil, ramdisk_id = nil,
          availability_zone = self.availability_zone, block_device_mappings = nil)
    # Create the corresponding node records in the db...
    node_descriptions.each do |node_description|
      currentnode = Node.new(:job_id => self.id)   
      currentnode.save
      update_node_info(currentnode, node_description)
    end
    puts "Waiting for nodes to boot"
    running_nodes = self.nodes.find(:all, :conditions => {:aws_state => "running"})      
    until running_nodes.size == nodecount do
       refresh_node_data_from_ec2(nodes.find(:all))
       running_nodes = self.nodes.find(:all, :conditions => {:aws_state => "running"})
       self.set_progress_message("#{running_nodes.size} of #{self.number_of_instances} started") 
       sleep 5         
    end
    return running_nodes
  end  
  
  
  def terminate_cluster_later
    # push cluster termination off to background using delayed_job
    self.send_later(:terminate_cluster)
    self.set_progress_message("sent shutdown request")     
  end
 
  
  def terminate_cluster    
    #TODO: add a check to see if delayed_job launch has been initiated
    # if it hasn't we need to delete the delayed job, for now we just block cancellation until nodes
    # have launched
    puts 'background cluster shutdown initiated...'  
    begin 
      self.nextstep! # cancellation_requested -> cancelling_job
      @ec2 = RightAws::Ec2.new(APP_CONFIG['aws_access_key_id'],
                                  APP_CONFIG['aws_secret_access_key'])
      self.set_progress_message("terminating cluster nodes")   
      # Only attempt to shut down running nodes...
      running_nodes = self.nodes.find(:all, :conditions => {:aws_state => "running" })
      running_instance_ids = get_instances_ids(running_nodes) 
      @ec2.terminate_instances(running_instance_ids)
      terminated_nodes = self.nodes.find(:all, :conditions => {:aws_state => "terminated" })
      # Loop until all nodes are terminated...
      until terminated_nodes.size == self.number_of_instances do
         refresh_node_data_from_ec2(running_nodes)
         terminated_nodes = self.nodes.find(:all, :conditions => {:aws_state => "terminated" })
         self.set_progress_message("#{terminated_nodes.size} of #{self.number_of_instances} terminated") 
         sleep 5         
      end 
      # Nodes are now terminated, delete associated EC2 security groups: 
      @ec2.delete_security_group(self.master_security_group)
      if self.number_of_instances > 1
        @ec2.delete_security_group(self.worker_security_group)
      end
      self.nextstep!
      self.set_progress_message("all cluster nodes terminated") 
      puts "Cluster termination completed successfully"         
    rescue Exception 
      puts "Error"
      # do something with error...
    end    
  end  
  
           
  def refresh_node_data_from_ec2(nodes)
    # @ec2 = RightAws::Ec2.new(APP_CONFIG['aws_access_key_id'],
    #                             APP_CONFIG['aws_secret_access_key'])
    nodes.each do |node|
      node_description = @ec2.describe_instances(node["aws_instance_id"])
      update_node_info(node, node_description[0])
    end
  end
    
  def get_instances_ids(nodes)
    return nodes.map { |node| node["aws_instance_id"] } 
  end           
         
  def update_node_info(node, node_description)
    node.aws_image_id = node_description[:aws_image_id]
    node.aws_instance_id = node_description[:aws_instance_id]
    node.aws_state = node_description[:aws_state]
    node.dns_name = node_description[:dns_name]
    node.ssh_key_name = node_description[:ssh_key_name]
    node.aws_groups = node_description[:aws_groups].join(" ")
    node.private_dns_name = node_description[:private_dns_name]
    node.aws_instance_type = node_description[:aws_instance_type]
    node.aws_launch_time = node_description[:aws_launch_time]
    node.aws_availability_zone = node_description[:aws_availability_zone]
    node.is_configured = false if node.is_configured.nil? 
    node.nfs_mounted = false if node.nfs_mounted.nil?       
    node.save
  end         
         
                              
protected

  def set_progress_message(message)
    update_attribute(:progress, message )
    self.save 
  end

  def set_start_time
    # Time when the cluster has actually booted and MPI job starts running
    update_attribute(:started_at, Time.now )
    self.set_progress_message("fetching input files from S3")          
    self.save 
  end
  
  def set_finish_time
    update_attribute(:finished_at, Time.now )
    self.save    
  end
  
  def set_cancelled_time
    update_attribute(:cancelled_at, Time.now )
    self.save    
  end
  
  def set_failed_time
    update_attribute(:failed_at, Time.now )
    self.save    
  end    

  def set_rest_url
    hostname = Socket.gethostname
    protocol = APP_CONFIG['protocol']
    self.mpi_service_rest_url = "#{protocol}://#{hostname}/"
    self.save        
  end
  
  def set_security_groups  
    timeval = Time.now.strftime('%m%d%y-%I%M%p')
    update_attribute(:master_security_group, "#{id}-ec2cluster-master-"+timeval)
    update_attribute(:worker_security_group, "#{id}-ec2cluster-worker-"+timeval)
    self.save    
  end  

  def set_master_instance_metadata(master_node)
    update_attribute(:master_instance_id, master_node.aws_instance_id )
    update_attribute(:master_hostname, master_node.private_dns_name )
    update_attribute(:master_public_hostname,  master_node.dns_name  )
    self.save
  end  


  def number_of_instances_must_be_at_least_1
    errors.add(:number_of_instances, 
    'You need at least 1 node in your cluster') if number_of_instances < 1
  end  

  # TODO: verify S3 buckets exist using right_aws before saving job
  # t.string   "output_path" 
  # t.string   "log_path"

  # TODO: verify s3 input files are accesible using right_aws before saving job
  # t.text     "input_files" 
  
end
