package DBIx::Tracer;
use strict;
use warnings;
use 5.008008;
our $VERSION = '0.01';

use DBI;
use Time::HiRes qw(gettimeofday);
use Carp;

my $org_execute               = \&DBI::st::execute;
my $org_bind_param            = \&DBI::st::bind_param;
my $org_db_do                 = \&DBI::db::do;
my $org_db_selectall_arrayref = \&DBI::db::selectall_arrayref;
my $org_db_selectrow_arrayref = \&DBI::db::selectrow_arrayref;
my $org_db_selectrow_array    = \&DBI::db::selectrow_array;

my $has_mysql = eval { require DBD::mysql; 1 } ? 1 : 0;
my $pp_mode   = $INC{'DBI/PurePerl.pm'} ? 1 : 0;

my $st_execute;
my $st_bind_param;
my $db_do;
my $selectall_arrayref;
my $selectrow_arrayref;
my $selectrow_array;

our $OUTPUT;

sub new {
    my $class = shift;

    # argument processing
    my %args;
    if (@_==1) {
        if (ref $_[0] eq 'CODE') {
            $args{code} = $_[0];
        } else {
            %args = %{$_[0]};
        }
    } else {
        %args = @_;
    }
    for (qw(code)) {
        unless ($args{$_}) {
            croak "Missing mandatory parameter $_ for DBIx::Tracer->new";
        }
    }

    my $logger = $args{code};

    # create object
    my $self = bless \%args, $class;

    # wrap methods
    my $st_execute    = $class->_st_execute($org_execute, $logger);
    $st_bind_param = $class->_st_bind_param($org_bind_param, $logger);
    $db_do         = $class->_db_do($org_db_do, $logger) if $has_mysql;
    unless ($pp_mode) {
        $selectall_arrayref = $class->_select_array($org_db_selectall_arrayref, 0, $logger);
        $selectrow_arrayref = $class->_select_array($org_db_selectrow_arrayref, 0, $logger);
        $selectrow_array    = $class->_select_array($org_db_selectrow_array, 1, $logger);
    }

    no warnings qw(redefine prototype);
    *DBI::st::execute    = $st_execute;
    *DBI::st::bind_param = $st_bind_param;
    *DBI::db::do         = $db_do if $has_mysql;
    unless ($pp_mode) {
        *DBI::db::selectall_arrayref = $selectall_arrayref;
        *DBI::db::selectrow_arrayref = $selectrow_arrayref;
        *DBI::db::selectrow_array    = $selectrow_array;
    }

    return $self;
}

sub DESTROY {
    my $self = shift;

    no warnings qw(redefine prototype);
    *DBI::st::execute    = $org_execute;
    *DBI::st::bind_param = $org_bind_param;
    *DBI::db::do         = $org_db_do if $has_mysql;
    unless ($pp_mode) {
        *DBI::db::selectall_arrayref = $org_db_selectall_arrayref;
        *DBI::db::selectrow_arrayref = $org_db_selectrow_arrayref;
        *DBI::db::selectrow_array    = $org_db_selectrow_array;
    }
}

# ------------------------------------------------------------------------- 
# wrapper methods.

sub _st_execute {
    my ($class, $org, $logger) = @_;

    return sub {
        my $sth = shift;
        my @params = @_;
        my @types;

        my $dbh = $sth->{Database};
        my $ret = $sth->{Statement};
        if (my $attrs = $sth->{private_DBIx_Tracer_attrs}) {
            my $bind_params = $sth->{private_DBIx_Tracer_params};
            for my $i (1..@$attrs) {
                push @types, $attrs->[$i - 1]{TYPE};
                push @params, $bind_params->[$i - 1] if $bind_params;
            }
        }
        $sth->{private_DBIx_Tracer_params} = undef;

        my $begin = [gettimeofday];
        my $wantarray = wantarray ? 1 : 0;
        my $res = $wantarray ? [$org->($sth, @_)] : scalar $org->($sth, @_);

        $class->_logging($logger, $dbh, $ret, $begin, \@params);

        return $wantarray ? @$res : $res;
    };
}

sub _st_bind_param {
    my ($class, $org) = @_;

    return sub {
        my ($sth, $p_num, $value, $attr) = @_;
        $sth->{private_DBIx_Tracer_params} ||= [];
        $sth->{private_DBIx_Tracer_attrs } ||= [];
        $attr = +{ TYPE => $attr || 0 } unless ref $attr eq 'HASH';
        $sth->{private_DBIx_Tracer_params}[$p_num - 1] = $value;
        $sth->{private_DBIx_Tracer_attrs }[$p_num - 1] = $attr;
        $org->(@_);
    };
}

sub _select_array {
    my ($class, $org, $is_selectrow_array, $logger) = @_;

    return sub {
        my $wantarray = wantarray;
        my ($dbh, $stmt, $attr, @bind) = @_;

        no warnings qw(redefine prototype);
        local *DBI::st::execute = $org_execute; # suppress duplicate logging

        my $ret = ref $stmt ? $stmt->{Statement} : $stmt;

        my $begin = [gettimeofday];
        my $res;
        if ($is_selectrow_array) {
            $res = $wantarray ? [$org->($dbh, $stmt, $attr, @bind)] : $org->($dbh, $stmt, $attr, @bind);
        }
        else {
            $res = $org->($dbh, $stmt, $attr, @bind);
        }

        $class->_logging($logger, $dbh, $ret, $begin, \@bind);

        if ($is_selectrow_array) {
            return $wantarray ? @$res : $res;
        }
        return $res;
    };
}

sub _db_do {
    my ($class, $org, $logger) = @_;

    return sub {
        my $wantarray = wantarray ? 1 : 0;
        my ($dbh, $stmt, $attr, @bind) = @_;

        if ($dbh->{Driver}{Name} ne 'mysql') {
            return $org->($dbh, $stmt, $attr, @bind);
        }

        my $ret = $stmt;

        my $begin = [gettimeofday];
        my $res = $wantarray ? [$org->($dbh, $stmt, $attr, @bind)] : scalar $org->($dbh, $stmt, $attr, @bind);

        $class->_logging($logger, $dbh, $ret, $begin, \@bind);

        return $wantarray ? @$res : $res;
    };
}

sub _logging {
    my ($class, $logger, $dbh, $sql, $time, $bind_params) = @_;
    $bind_params ||= [];

    $logger->(
        dbh         => $dbh,
        time        => $time,
        sql         => $sql,
        bind_params => $bind_params,
    );
}

1;
__END__

=encoding utf8

=head1 NAME

DBIx::Tracer - A module for you

=head1 SYNOPSIS

  use DBIx::Tracer;

=head1 DESCRIPTION

DBIx::Tracer is

=head1 AUTHOR

Tokuhiro Matsuno E<lt>tokuhirom AAJKLFJEF@ GMAIL COME<gt>

=head1 SEE ALSO

=head1 LICENSE

Copyright (C) Tokuhiro Matsuno

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
