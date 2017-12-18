
require 'digest'
require 'xxhash'
require 'terrafying/generator'
require 'terrafying/util'

PORT_NAMES = {
  22 => "ssh",
  80 => "http",
  443 => "https",
  1194 => "openvpn",
}

def enrich_ports(ports)
  ports.map { |port|
    if port.is_a?(Numeric)
      port = { number: port }
    end

    port = {
      type: "tcp",
      name: PORT_NAMES.fetch(port[:number], port[:number].to_s),
    }.merge(port)

    port
  }
end

def is_l4_port(port)
  port[:type] == "tcp" || port[:type] == "udp"
end

def is_l7_port(port)
  port[:type] == "http" || port[:type] == "https"
end


module Terrafying

  module Components

    class Service < Terrafying::Context

      attr_reader :name, :ids, :fqdn, :instance_fqdns, :instance_security_group

      def self.create_in(vpc, name, options={})
        Service.new.create_in vpc, name, options
      end

      def initialize()
        super
      end


      def create_in(vpc, name, options={})
        options = {
          ami: aws.ami("CoreOS-stable-1576.4.0-hvm", owners=["595879546273"]),
          instance_type: "t2.micro",
          public: false,
          internet_egress: false,
          ports: [],
          instances: [{}],
          zone: vpc.zone,
          iam_policy_statements: [],
          security_groups: [],
          keypairs: [],
          volumes: [],
          units: [],
          files: [],
          tags: {},
          ssh_group: vpc.ssh_group,
          subnets: nil,
          pivot: false,
        }.merge(options)

        if ! options.has_key? :user_data
          options[:user_data] = user_data(options)
        end

        ident = "#{vpc.name}-#{name}"

        @name = ident
        @fqdn = options[:zone].qualify(name)
        @instance_fqdns = []
        @ports = enrich_ports(options[:ports])
        @ssh_group = options[:ssh_group]

        if options[:subnets]
          subnets = options[:subnets]
        elsif options[:public]
          subnets = vpc.public_subnets
        else
          subnets = vpc.private_subnets
        end

        @access_security_group = resource :aws_security_group, ident, {
                                            name: "service-#{ident}",
                                            description: "Describe the ingress and egress of the service #{ident}",
                                            tags: options[:tags],
                                            vpc_id: vpc.id,
                                            egress: [
                                              {
                                                from_port: 0,
                                                to_port: 0,
                                                protocol: -1,
                                                cidr_blocks: [options[:internet_egress] ? vpc.cidr : "0.0.0.0/0"],
                                              }
                                            ],
                                          }

        resource :aws_iam_role, ident, {
                   name: ident,
                   assume_role_policy: JSON.pretty_generate({
                                                              Version: "2012-10-17",
                                                              Statement: [
                                                                {
                                                                  Effect: "Allow",
                                                                  Principal: { "Service": "ec2.amazonaws.com"},
                                                                  Action: "sts:AssumeRole"
                                                                }
                                                              ]
                                                            })
                 }
        resource :aws_iam_role_policy, ident, {
                   name: ident,
                   policy: JSON.pretty_generate({
                                                  Version: "2012-10-17",
                                                  Statement: [
                                                    {
                                                      Sid: "Stmt1442396947000",
                                                      Effect: "Allow",
                                                      Action: [
                                                        "iam:GetGroup",
                                                        "iam:GetSSHPublicKey",
                                                        "iam:GetUser",
                                                        "iam:ListSSHPublicKeys"
                                                      ],
                                                      Resource: [
                                                        "arn:aws:iam::*"
                                                      ]
                                                    }
                                                  ].push(*options[:keypairs].map{|kp| kp[:iam_statement]}).push(*options[:iam_policy_statements])
                                                }),
                   role: output_of(:aws_iam_role, ident, :name)
                 }
        instance_profile = resource :aws_iam_instance_profile, ident, {
                                      name: ident,
                                      role: output_of(:aws_iam_role, ident, :name),
                                    }


        if options[:instances].is_a?(Hash)

          if @ports.count > 0
            l4_ports = @ports.select { |p| is_l4_port(p) }
            l7_ports = @ports.select { |p| is_l7_port(p) }

            target_groups = []


            @instance_security_group = resource :aws_security_group, "asg-#{ident}", {
                                                  name: "asg-#{ident}",
                                                  description: "Describe the ingress and egress of the service asg #{ident}",
                                                  tags: options[:tags],
                                                  vpc_id: vpc.id,
                                                  egress: [
                                                    {
                                                      from_port: 0,
                                                      to_port: 0,
                                                      protocol: -1,
                                                      cidr_blocks: [options[:internet_egress] ? vpc.cidr : "0.0.0.0/0"],
                                                    }
                                                  ],
                                                }


            if l4_ports.count > 0
              network_load_balancer = resource :aws_lb, "nlb-#{ident}", {
                                                 name: "nlb-#{ident}",
                                                 load_balancer_type: "network",
                                                 internal: !options[:public],
                                                 subnets: subnets.map(&:id),
                                                 tags: options[:tags],
                                               }

              l4_ports.each { |l4_port|
                port_ident = "nlb-#{ident}-#{l4_port[:type]}-#{l4_port[:number]}"
                target_group = resource :aws_lb_target_group, port_ident, {
                                          name: port_ident,
                                          port: l4_port[:number],
                                          protocol: l4_port[:type].upcase,
                                          vpc_id: vpc.id,
                                        }.merge(l4_port.has_key?(:health_check) ? { health_check: l4_port[:health_check] }: {})

                resource :aws_security_group_rule, port_ident, {
                           security_group_id: @instance_security_group,
                           type: "ingress",
                           from_port: l4_port[:number],
                           to_port: l4_port[:number],
                           protocol: l4_port[:type],
                           cidr_blocks: [ vpc.cidr ], # until we can get the ips for the nlb it has to be all vpc
                         }

                resource :aws_lb_listener, port_ident, {
                           load_balancer_arn: network_load_balancer,
                           port: l4_port[:number],
                           protocol: l4_port[:type].upcase,
                           default_action: {
                             target_group_arn: target_group,
                             type: "forward",
                           },
                         }

                l4_port[:security_group] = @instance_security_group

                target_groups << target_group
              }
            end

            if l7_ports.count > 0
              application_load_balancer = resource :aws_lb, "alb-#{ident}", {
                                                     name: "alb-#{ident}",
                                                     load_balancer_type: "application",
                                                     security_groups: [@access_security_group],
                                                     internal: !options[:public],
                                                     subnets: subnets.map(&:id),
                                                     tags: options[:tags],
                                                   }

              l7_ports.each { |l7_port|
                port_ident = "alb-#{ident}-#{l7_port[:type]}-#{l7_port[:number]}"
                target_group = resource :aws_lb_target_group, port_ident, {
                                          name: port_ident,
                                          port: l7_port[:number],
                                          protocol: l7_port[:type].upcase,
                                          vpc_id: vpc.id,
                                        }.merge(l7_port.has_key?(:health_check) ? { health_check: l7_port[:health_check] }: {})

                resource :aws_security_group_rule, port_ident, {
                           security_group_id: @instance_security_group,
                           type: "ingress",
                           from_port: l7_port[:number],
                           to_port: l7_port[:number],
                           protocol: "tcp",
                           source_security_group_ids: [
                             @access_security_group,
                           ],
                         }

                ssl_options = {}
                if l7_port.has_key?(:ssl_certificate)
                  ssl_options = {
                    ssl_policy: "ELBSecurityPolicy-2015-05",
                    certificate_arn: l7_port[:ssl_certificate],
                  }
                end

                resource :aws_lb_listener, port_ident, {
                           load_balancer_arn: application_load_balancer,
                           port: l7_port[:number],
                           protocol: l7_port[:type].upcase,
                           default_action: {
                             target_group_arn: target_group,
                             type: "forward",
                           },
                         }.merge(ssl_options)

                target_groups << target_group
              }
            end

            if application_load_balancer
              options[:zone].add_alias(
                name,
                {
                  name: output_of(:aws_lb, "alb-#{ident}", :dns_name),
                  zone_id: output_of(:aws_lb, "alb-#{ident}", :zone_id),
                  evaluate_target_health: true,
                },
              )
            elsif network_load_balancer
              options[:zone].add_alias(
                name,
                {
                  name: output_of(:aws_lb, "nlb-#{ident}", :dns_name),
                  zone_id: output_of(:aws_lb, "nlb-#{ident}", :zone_id),
                  evaluate_target_health: true,
                },
              )
            end
          else
            @instance_security_group = @access_security_group
          end

          launch_config = resource :aws_launch_configuration, ident, {
                                     name_prefix: "#{ident}-",
                                     image_id: options[:ami],
                                     instance_type: options[:instance_type],
                                     user_data: options[:user_data],
                                     iam_instance_profile: instance_profile,
                                     associate_public_ip_address: options[:public],
                                     root_block_device: {
                                       volume_type: 'gp2',
                                       volume_size: 32,
                                     },
                                     security_groups: [
                                       vpc.internal_ssh_security_group,
                                       @instance_security_group,
                                     ].push(*options[:security_groups]),
                                     lifecycle: {
                                       create_before_destroy: true,
                                     },
                                     depends_on: [
                                       "aws_iam_instance_profile.#{ident}",
                                     ],
                                   }

          if options[:pivot]
            @ids = subnets.map.with_index { |subnet, i|
              resource :aws_autoscaling_group, "#{ident}-#{i}", {
                         name: "#{ident}-#{i}",
                         launch_configuration: launch_config,
                         min_size: options[:instances][:min],
                         max_size: options[:instances][:max],
                         desired_capacity: options[:instances][:desired],
                         vpc_zone_identifier: [subnet.id],
                         tags: {
                           Name: ident,
                           service_name: name,
                         }.merge(options[:tags]).map { |k,v|
                           { key: k, value: v, propagate_at_launch: true }
                         },
                       }.merge(target_groups ? {target_group_arns: target_groups} : {})
            }
          else
            asg = resource :aws_autoscaling_group, ident, {
                                name: ident,
                                launch_configuration: launch_config,
                                min_size: options[:instances][:min],
                                max_size: options[:instances][:max],
                                desired_capacity: options[:instances][:desired],
                                vpc_zone_identifier: subnets.map(&:id),
                                tags: {
                                  Name: ident,
                                  service_name: name,
                                }.merge(options[:tags]).map { |k,v|
                                  { key: k, value: v, propagate_at_launch: true }
                                },
                           }.merge(target_groups ? {target_group_arns: target_groups} : {})

            @ids = [asg]
          end

        elsif options[:instances].is_a?(Array)

          instance_ip = options[:public] ? :public_ip : :private_ip

          @instance_security_group = @access_security_group

          @ids = options[:instances].map.with_index {|config, i|
            instance_ident = "#{ident}-#{i}"

            if config.has_key? :subnet and config.has_key? :ip_address
              subnet = config[:subnet]
              ip_address = config[:ip_address]
              lifecycle = {
                lifecycle: { create_before_destroy: false },
              }
            else
              # pick something consistent but not just the first subnet
              subnet_index = XXhash.xxh32(ident) % subnets.count
              subnet = subnets[subnet_index]
              lifecycle = {
                lifecycle: { create_before_destroy: true },
              }
            end

            instance_id = resource :aws_instance, instance_ident, {
                                     ami: options[:ami],
                                     instance_type: options[:instance_type],
                                     iam_instance_profile: instance_profile,
                                     subnet_id: subnet.id,
                                     associate_public_ip_address: options[:public],
                                     root_block_device: {
                                       volume_type: 'gp2',
                                       volume_size: 32,
                                     },
                                     tags: {
                                       'Name' => "#{ident}-#{i}",
                                     }.merge(options[:tags]),
                                     vpc_security_group_ids: [
                                       vpc.internal_ssh_security_group,
                                       @instance_security_group,
                                     ].push(*options[:security_groups]),
                                     user_data: options[:user_data],
                                     lifecycle: {
                                       create_before_destroy: true,
                                     },
                                   }.merge(ip_address ? { private_ip: ip_address } : {}).merge(lifecycle)

            options[:volumes].each.with_index { |volume, vol_i|
              volume_name = "#{instance_ident}-#{vol_i}"
              volume_id = resource :aws_ebs_volume, volume_name, {
                                     availability_zone: subnet.az,
                                     size: volume[:size],
                                     type: volume.fetch(:type, "gp2"),
                                     tags: {
                                       Name: volume_name,
                                     }.merge(options[:tags]),
                                   }

              resource :aws_volume_attachment, volume_name, {
                         device_name: volume[:device],
                         volume_id: volume_id,
                         instance_id: instance_id,
                         force_detach: true,
                       }
            }

            @instance_fqdns.push(options[:zone].qualify("#{name}-#{i}"))
            options[:zone].add_record_in(
              self,
              "#{name}-#{i}",
              [output_of(:aws_instance, instance_ident, instance_ip)],
            )

            instance_id
          }

          options[:zone].add_record_in(
            self,
            name,
            @ids.map.with_index {|_, i| output_of(:aws_instance, "#{ident}-#{i}", instance_ip) },
          )

          @ports.each { |port|
            resource :aws_security_group_rule, "#{@name}-to-self-#{port[:name]}", {
                       security_group_id: @instance_security_group,
                       type: "ingress",
                       from_port: port[:number],
                       to_port: port[:number],
                       protocol: port[:type],
                       self: true,
                     }

            options[:zone].add_srv(
              name, port[:name], port[:number], port[:type],
              @ids.map.with_index { |_, i| "#{name}-#{i}" },
            )
          }

        else

          raise "Don't know what kind of service this is"

        end

        self
      end

      def user_data(options={})
        options = {
          keypairs: [],
          volumes: [],
          units: [],
          files: [],
          ssh_group: @ssh_group,
        }.merge(options)

        options[:cas] = options[:keypairs].map { |kp| kp[:ca] }.sort.uniq

        yaml = template("templates/service.yaml", options)

        Terrafying::Util.to_ignition(yaml)
      end

      def used_by(other_service)
        @ports.map {|port|
          resource :aws_security_group_rule, "#{@name}-to-#{other_service.name}-#{port[:name]}", {
                     security_group_id: port.fetch(:security_group, @access_security_group),
                     type: "ingress",
                     from_port: port[:number],
                     to_port: port[:number],
                     protocol: port[:type],
                     source_security_group_id: other_service.instance_security_group,
                   }
        }
      end

      def used_by_cidr(*cidrs)
        cidrs.map { |cidr|
          cidr_ident = cidr.gsub(/[\.\/]/, "-")

          @ports.map {|port|
            resource :aws_security_group_rule, "#{@name}-to-#{cidr_ident}-#{port[:name]}", {
                       security_group_id: port.fetch(:security_group, @access_security_group),
                       type: "ingress",
                       from_port: port[:number],
                       to_port: port[:number],
                       protocol: port[:type],
                       cidr_blocks: [cidr],
                     }
          }
        }
      end

    end

  end

end
