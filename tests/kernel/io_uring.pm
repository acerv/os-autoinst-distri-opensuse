# SUSE's openQA tests
#
# Copyright 2023 SUSE LLC
# SPDX-License-Identifier: FSFAP
#
# Summary: Executes liburing testing suite
# Maintainer: Kernel QE <kernel-qa@suse.de>
# More documentation is at the bottom

use base 'opensusebasetest';
use strict;
use warnings;
use testapi;
use serial_terminal 'select_serial_terminal';
use utils;
use LTP::WhiteList;
use version_utils qw(is_transactional);
use transactional 'trup_install';

sub run
{
    my ($self) = @_;

    select_serial_terminal;

    # check if liburing2 is installed and eventually install it
    my $pkgs = "git-core";
    $pkgs .= " liburing2" if script_run('rpm -q liburing2');

    # install dependences
    zypper_call("ref");

    if (is_transactional) {
        trup_install("gcc gcc-c++ make $pkgs");
    } else {
        zypper_call("in -t pattern devel_basis");
        zypper_call("in $pkgs");
    }

    # select latest liburing version which is supported by the system
    my $version = get_var('LIBURING_VERSION', '');
    my $out;
    if ($version eq '') {
        $out = script_output('rpm -q --qf "%{Version}\n" liburing2 | sort -nr | head -1');
        $version = "liburing-$out";
    }

    # download and compile tests
    my $repository = get_var('LIBURING_REPO', 'https://github.com/axboe/liburing.git');

    assert_script_run("git clone --no-single-branch $repository");
    assert_script_run("cd liburing");
    assert_script_run("git checkout $version");
    assert_script_run("./configure");
    assert_script_run("make -C src");
    assert_script_run("make -C test");

    # create environment information for known issues check
    my $environment = {
        product => get_var('DISTRI') . ':' . get_var('VERSION'),
        revision => get_var('BUILD'),
        flavor => get_var('FLAVOR'),
        arch => get_var('ARCH'),
        backend => get_var('BACKEND'),
        kernel => script_output('uname -r'),
        libc => '',
        gcc => '',
        harness => 'SUSE OpenQA',
        ltp_version => $version
    };

    # run tests executables
    my $exclude = get_var('LIBURING_EXCLUDE', '');
    my $issues = get_var('LIBURING_KNOWN_ISSUES', '');
    my $whitelist = LTP::WhiteList->new($issues);
    my @skipped = $whitelist->list_skipped_tests($environment, 'liburing');
    if (@skipped) {
        push @skipped, $exclude if $exclude;
        my $test_exclude = join('|', @skipped);

        record_info(
            "Exclude",
            "Excluding tests: $test_exclude",
            result => 'softfail'
        );

        set_var('KIRK_SKIP', "$test_exclude");
    }

    $out = script_output("make -C test", timeout => 1800);

    # setup kirk framework before calling it
    set_var('KIRK_FRAMEWORK', "liburing:root=/root/liburing/test");
    set_var('KIRK_SUITE', "default");
}

1;

=head1 Discussion

Test module to run liburing testing suite.

=head1 Configuration

=head2 LIBURING_REPO

The liburing repository

=head2 LIBURING_VERSION

The liburing version

=head2 LIBURING_EXCLUDE

The liburing tests which we want to exclude. This can be useful for debugging.

=head2 LIBURING_KNOWN_ISSUES

The liburing tests which have known issues if they fail
