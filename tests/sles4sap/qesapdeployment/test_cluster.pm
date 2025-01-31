# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

# Summary: Test for qe-sap-deployment
# Maintainer: QE-SAP <qe-sap@suse.de>, Michele Pagot <michele.pagot@suse.com>

use strict;
use warnings;
use Mojo::Base 'publiccloud::basetest';
use testapi;
use qesapdeployment;
use hacluster '$crm_mon_cmd';

sub run {
    my ($self) = @_;
    my $inventory = qesap_get_inventory(get_required_var('PUBLIC_CLOUD_PROVIDER'));
    my $prov = get_required_var('PUBLIC_CLOUD_PROVIDER');

    my $chdir = qesap_get_terraform_dir();
    assert_script_run("terraform -chdir=$chdir output");
    my @remote_cmd = (
        'pwd',
        'uname -a',
        'cat /etc/os-release',
        'sudo SUSEConnect --status-text',
        'zypper ref',
        'zypper lr',
        'zypper in -f -y vim'
    );
    qesap_ansible_cmd(cmd => $_, provider => $prov) for @remote_cmd;
    qesap_ansible_cmd(cmd => 'ls -lai /hana/', provider => $prov, filter => 'hana');
    my $cmr_status = qesap_ansible_script_output(cmd => 'crm status', provider => $prov, host => '"hana[0]"', root => 1);
    record_info("crm status", $cmr_status);
    qesap_ansible_cmd(cmd => $crm_mon_cmd, provider => $prov, filter => '"hana[0]"');
    qesap_cluster_logs();

    if (check_var('PUBLIC_CLOUD_PROVIDER', 'AZURE')) {
        if (get_var("QESAPDEPLOY_IBSMIRROR_RESOURCE_GROUP")) {
            my $rg = qesap_az_get_resource_group();
            my $ibs_mirror_rg = get_var('QESAPDEPLOY_IBSMIRROR_RESOURCE_GROUP');
            qesap_az_vnet_peering(source_group => $rg, target_group => $ibs_mirror_rg);
            qesap_add_server_to_hosts(name => 'download.suse.de', ip => get_required_var("QESAPDEPLOY_IBSMIRROR_IP"));
            qesap_az_vnet_peering_delete(source_group => $rg, target_group => $ibs_mirror_rg);
        }
    } elsif (check_var('PUBLIC_CLOUD_PROVIDER', 'EC2')) {
        if (get_var("QESAPDEPLOY_IBSMIRROR_IP_RANGE")) {
            my $deployment_name = qesap_calculate_deployment_name('qesapval');
            my $vpc_id = qesap_aws_get_vpc_id(resource_group => $deployment_name);
            my $ibs_mirror_target_ip = get_var('QESAPDEPLOY_IBSMIRROR_IP_RANGE');    # '10.254.254.240/28'
            die 'Error in network peering setup.' if !qesap_aws_vnet_peering(target_ip => $ibs_mirror_target_ip, vpc_id => $vpc_id);
            qesap_add_server_to_hosts(name => 'download.suse.de', ip => get_required_var("QESAPDEPLOY_IBSMIRROR_IP"));
            die 'Error in network peering delete.' if !qesap_aws_delete_transit_gateway_vpc_attachment(name => $deployment_name . '*');
        }
    }
}

sub post_fail_hook {
    my ($self) = shift;
    qesap_upload_logs();
    qesap_execute(cmd => 'ansible', cmd_options => '-d', verbose => 1, timeout => 300);
    qesap_execute(cmd => 'terraform', cmd_options => '-d', verbose => 1, timeout => 1200);
    if (check_var('PUBLIC_CLOUD_PROVIDER', 'AZURE')) {
        if (get_var("QESAPDEPLOY_IBSMIRROR_RESOURCE_GROUP")) {
            my $rg = qesap_az_get_resource_group();
            my $ibs_mirror_rg = get_required_var('QESAPDEPLOY_IBSMIRROR_RESOURCE_GROUP');
            qesap_az_vnet_peering_delete(source_group => $rg, target_group => $ibs_mirror_rg);
        }
    } elsif (check_var('PUBLIC_CLOUD_PROVIDER', 'EC2')) {
        if (get_var("QESAPDEPLOY_IBSMIRROR_IP_RANGE")) {
            qesap_aws_delete_transit_gateway_vpc_attachment(name => qesap_calculate_deployment_name('qesapval') . '*');
        }
    }
    $self->SUPER::post_fail_hook;
}

1;
