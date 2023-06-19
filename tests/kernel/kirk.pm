# SUSE's openQA tests
#
# Copyright 2023 SUSE LLC
# SPDX-License-Identifier: FSFAP
#
# Summary: Executes kirk testing framework
# Maintainer: Kernel QE <kernel-qa@suse.de>

use base 'opensusebasetest';
use utils;
use strict;
use testapi;
use bmwqemu;
use serial_terminal 'select_serial_terminal';
use Mojo::File;
use Mojo::JSON;
use LTP::WhiteList;

our $result_file = 'result.json';

sub upload_logs
{
    my ($self) = @_;
    my $log_file = Mojo::File::path($result_file);
    my $suites = get_required_var('KIRK_SUITES');

    record_info('LTP Logs', 'upload');
    upload_logs($result_file, log_name => $log_file->basename, failok => 1);

    assert_script_run("test -f /tmp/kirk.\$USER/latest/debug.log || echo No debug log");
    upload_logs("/tmp/kirk.\$USER/latest/debug.log", failok => 1);

    return unless -e $log_file->to_string;

    local @INC = ($ENV{OPENQA_LIBPATH} // testapi::OPENQA_LIBPATH, @INC);
    eval {
        require OpenQA::Parser::Format::LTP;

        my $ltp_log = Mojo::JSON::decode_json($log_file->slurp());
        my $parser = OpenQA::Parser::Format::LTP->new()->load($log_file->to_string);
        my %ltp_log_results = map { $_->{test_fqn} => $_->{test} } @{$ltp_log->{results}};
        my $whitelist = LTP::WhiteList->new();

        for my $result (@{$parser->results()}) {
            if ($whitelist->override_known_failures(
                    $self,
                    {%{$self->{ltp_env}},
                    retval => $ltp_log_results{$result->{test_fqn}}->{retval}},
                    $suites,
                    $result->{test_fqn})) {
                $result->{result} = 'softfail';
            }
        }

        $parser->write_output(bmwqemu::result_dir());
        $parser->write_test_result(bmwqemu::result_dir());

        $parser->tests->each(sub {
                $autotest::current_test->register_extra_test_results([$_->to_openqa]);
        });
    };
    die $@ if $@;
}

sub run
{
    my ($self) = @_;
    my $repo = get_var('KIRK_REPO', 'https://github.com/acerv/kirk.git');
    my $branch = get_var('KIRK_BRANCH', 'master');
    my $timeout = get_var('KIRK_TIMEOUT', '5400');
    my $framework = get_var('KIRK_FRAMEWORK', 'ltp:root=/opt/ltp');
    my $sut = get_var('KIRK_SUT', 'host');
    my $skip = get_var('KIRK_SKIP', '');
    my $envs = get_var('KIRK_ENVS', '');
    my $opts = get_var('KIRK_OPTIONS', '');
    my $suite = get_var('KIRK_SUITES', '');

    select_serial_terminal;

    zypper_call("in -y git");
    assert_script_run("git clone -q --single-branch -b $branch --depth 1 $repo");

    my $cmd = 'python3 kirk/kirk ';
    $cmd .= "--verbose ";
    $cmd .= "--suite-timeout $timeout ";
    $cmd .= "--framework $framework ";
    $cmd .= "--sut $sut ";
    $cmd .= "--json-report $result_file ";
    $cmd .= "--skip-tests $skip " if $skip;
    $cmd .= "--env $envs " if $envs;
    $cmd .= "$opts " if $opts;
    $cmd .= "--run-suite $suite";

    assert_script_run($cmd, timeout => $timeout);
}

sub cleanup
{
    my ($self) = @_;

    $self->upload_logs();
}

1;
