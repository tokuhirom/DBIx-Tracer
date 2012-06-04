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

    # create object
    my $self = bless \%args, $class;

    # wrap methods
    $st_execute    ||= $self->_st_execute($org_execute);
    $st_bind_param ||= $self->_st_bind_param($org_bind_param);
    $db_do         ||= $self->_db_do($org_db_do) if $has_mysql;
    unless ($pp_mode) {
        $selectall_arrayref ||= $self->_select_array($org_db_selectall_arrayref);
        $selectrow_arrayref ||= $self->_select_array($org_db_selectrow_arrayref);
        $selectrow_array    ||= $self->_select_array($org_db_selectrow_array, 1);
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
}

sub disable {
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
    my ($self, $org) = @_;
    
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

        $self->_logging($dbh, $ret, $begin, \@params);

        return $wantarray ? @$res : $res;
    };
}

sub _st_bind_param {
    my ($self, $org) = @_;

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
    my ($self, $org, $is_selectrow_array) = @_;

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

        $self->_logging($dbh, $ret, $begin, \@bind);

        if ($is_selectrow_array) {
            return $wantarray ? @$res : $res;
        }
        return $res;
    };
}

sub _db_do {
    my ($self, $org) = @_;

    return sub {
        my $wantarray = wantarray ? 1 : 0;
        my ($dbh, $stmt, $attr, @bind) = @_;

        if ($dbh->{Driver}{Name} ne 'mysql') {
            return $org->($dbh, $stmt, $attr, @bind);
        }

        my $ret = $stmt;

        my $begin = [gettimeofday];
        my $res = $wantarray ? [$org->($dbh, $stmt, $attr, @bind)] : scalar $org->($dbh, $stmt, $attr, @bind);

        $self->_logging($dbh, $ret, $begin, \@bind);

        return $wantarray ? @$res : $res;
    };
}

sub _logging {
    my ($self, $dbh, $sql, $time, $bind_params) = @_;
    $bind_params ||= [];

    $self->{code}->(
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
