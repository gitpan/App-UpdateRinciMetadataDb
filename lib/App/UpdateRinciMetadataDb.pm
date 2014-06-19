package App::UpdateRinciMetadataDb;

use 5.010001;
use strict;
use warnings;
use experimental 'smartmatch';
use Log::Any '$log';

use Data::Clean::JSON;
use DBI;
use JSON;
use Module::List;
use Module::Path;
use Perinci::Access::Perl;
use SHARYANTO::SQL::Schema;

our $VERSION = '0.01'; # VERSION
our $DATE = '2014-06-19'; # DATE

use Data::Clean::JSON;
use Perinci::CmdLine;

my $cleanser = Data::Clean::JSON->get_cleanser;

our %SPEC;

$SPEC{update_rinci_metadata_db} = {
    v => 1.1,
    summary => 'Create/update Spanel API metadata database',
    args => {
        dsn => {
            summary => 'DBI connection DSN',
            description => <<'_',

Note: has been tested with SQLite only.

_
            schema => 'str*',
            req => 1,
            pos => 0,
        },
        user => {
            summary => 'DBI connection user',
            schema => 'str*',
        },
        password => {
            summary => 'DBI connection password',
            schema => 'str*',
        },
        module => {
            summary => 'Perl module or prefixes to add/update',
            schema => ['array*' => of => 'str*'],
            req => 1,
            pos => 1,
            greedy => 1,
        },
        library => {
            summary => "Include library path, like Perl's -I",
            description => <<'_',

Note that some modules are already loaded before this option takes effect. To
make sure you use the right library, you can use `PERL5OPT` or explicitly use
`perl` and use its `-I` option.

_
            cmdline_aliases => { I=>{} },
        },
        force => {
            summary => "Force update database even though module ".
                "hasn't changed since last update",
            schema => 'bool',
        },
    },
    features => {
        progress => 1,
        dry_run => 1,
    },
};
sub update_rinci_metadata_db {
    my %args = @_;
    for my $dir (@{ $args{library} // [] }) {
        require lib;
        lib->import($dir);
    }

    require DBI;
    require JSON;
    require Module::List;
    require Module::Path;
    require Perinci::Access::Perl;
    require SHARYANTO::SQL::Schema;

    state $json = JSON->new->allow_nonref;
    state $pa = Perinci::Access::Perl->new;

    my $dbh = DBI->connect($args{dsn}, $args{user}, $args{password},
                           {RaiseError=>1});

    my $res = SHARYANTO::SQL::Schema::create_or_update_db_schema(
        spec => {
            install => [
                'CREATE TABLE IF NOT EXISTS module (name TEXT PRIMARY KEY, summary TEXT, metadata BLOB, mtime INT)',
                'CREATE TABLE IF NOT EXISTS function (module TEXT NOT NULL, name TEXT NOT NULL, summary TEXT, metadata BLOB, UNIQUE(module, name))',
            ],
        },
        dbh => $dbh,
    );
    return $res unless $res->[0] == 200;

    my @mods;
    for (@{ $args{module} }) {
        if (/::$/) {
            my $res = Module::List::list_modules(
                $_, {list_modules=>1, recurse=>1});
            for (sort keys %$res) {
                push @mods, $_ unless $_ ~~ @mods;
            }
        } else {
            push @mods, $_ unless $_ ~~ @mods;
        }
    }

    my $progress = $args{-progress};
    $progress->pos(0);
    $progress->target(~~@mods);
    my $i = 0;
    for my $mod (@mods) {
        $i++;
        $progress->update(pos=>$i, message => "Processing module $mod ...");
        $log->debug("Processing module $mod ...");
        #sleep 1;
        my $rec = $dbh->selectrow_hashref("SELECT * FROM module WHERE name=?",
                                          {}, $mod);
        my $mp = Module::Path::module_path($mod);
        my @st = stat($mp);

        unless ($args{force} || !$rec || !$rec->{mtime} || $rec->{mtime} < $st[9]) {
            $log->debug("$mod ($mp) hasn't changed since last recorded, skipped");
            next;
        }

        next if $args{-dry_run};

        my $uri = $mod; $uri =~ s!::!/!g; $uri = "pl:/$uri/";

        $res = $pa->request(meta => "$uri");
        die "Can't meta $uri: $res->[0] - $res->[1]" unless $res->[0] == 200;
        $cleanser->clean_in_place(my $pkgmeta = $res->[2]);

        $res = $pa->request(list => $uri, {type=>'function'});
        die "Can't list $uri: $res->[0] - $res->[1]" unless $res->[0] == 200;
        my $numf = @{ $res->[2] };

        $dbh->do("INSERT INTO module (name, summary, metadata, mtime) VALUES (?,?,?,0)", {}, $mod, $pkgmeta->{summary}, $json->encode($pkgmeta), $st[9]) unless $rec;
        $dbh->do("UPDATE module set mtime=? WHERE name=?", {}, $st[9], $mod);
        $dbh->do("DELETE FROM function WHERE module=?", {}, $mod);
        my $j = 0;
        for my $e (@{ $res->[2] }) {
            my $f = $e; $f =~ s!.+/!!;
            $j++;
            $log->debug("Processing function $mod\::$f ...");
            $progress->update(pos => $i + $j/$numf, message => "Processing function $mod\::$f ...");
            $res = $pa->request(meta => "$uri$e");
            die "Can't meta $e: $res->[0] - $res->[1]" unless $res->[0] == 200;
            $cleanser->clean_in_place(my $meta = $res->[2]);
            $dbh->do("INSERT INTO function (module, name, summary, metadata) VALUES (?,?,?,?)", {}, $mod, $f, $meta->{summary}, $json->encode($meta));
        }
    }
    $progress->finish;

    my @deleted_mods;
    my $sth = $dbh->prepare("SELECT name FROM module");
    $sth->execute;
    while (my $row = $sth->fetchrow_hashref) {
        next if $row->{name} ~~ @mods;
        $log->info("Module $row->{name} no longer exists, deleting from database ...");
        push @deleted_mods, $row->{name};
    }
    if (@deleted_mods && !$args{-dry_run}) {
        my $in = join(",", map {$dbh->quote($_)} @deleted_mods);
        $dbh->do("DELETE FROM function WHERE module IN ($in)");
        $dbh->do("DELETE FROM module WHERE name IN ($in)");
    }

    [200, "OK"];
}

1;
# ABSTRACT: Create/update Rinci metadata database

__END__

=pod

=encoding UTF-8

=head1 NAME

App::UpdateRinciMetadataDb - Create/update Rinci metadata database

=head1 VERSION

This document describes version 0.01 of App::UpdateRinciMetadataDb (from Perl distribution App-UpdateRinciMetadataDb), released on 2014-06-19.

=head1 FUNCTIONS


=head2 update_rinci_metadata_db(%args) -> [status, msg, result, meta]

Create/update Spanel API metadata database.

This function supports dry-run operation.


Arguments ('*' denotes required arguments):

=over 4

=item * B<dsn>* => I<str>

DBI connection DSN.

Note: has been tested with SQLite only.

=item * B<force> => I<bool>

Force update database even though module hasn't changed since last update.

=item * B<library> => I<any>

Include library path, like Perl's -I.

Note that some modules are already loaded before this option takes effect. To
make sure you use the right library, you can use C<PERL5OPT> or explicitly use
C<perl> and use its C<-I> option.

=item * B<module>* => I<array>

Perl module or prefixes to add/update.

=item * B<password> => I<str>

DBI connection password.

=item * B<user> => I<str>

DBI connection user.

=back

Special arguments:

=over 4

=item * B<-dry_run> => I<bool>

Pass -dry_run=>1 to enable simulation mode.

=back

Return value:

Returns an enveloped result (an array).

First element (status) is an integer containing HTTP status code
(200 means OK, 4xx caller error, 5xx function error). Second element
(msg) is a string containing error message, or 'OK' if status is
200. Third element (result) is optional, the actual result. Fourth
element (meta) is called result metadata and is optional, a hash
that contains extra information.

=head1 HOMEPAGE

Please visit the project's homepage at L<https://metacpan.org/release/App-UpdateRinciMetadataDb>.

=head1 SOURCE

Source repository is at L<https://github.com/sharyanto/perl-App-UpdateRinciMetadataDb>.

=head1 BUGS

Please report any bugs or feature requests on the bugtracker website L<https://rt.cpan.org/Public/Dist/Display.html?Name=App-UpdateRinciMetadataDb>

When submitting a bug or request, please include a test-file or a
patch to an existing test-file that illustrates the bug or desired
feature.

=head1 AUTHOR

Steven Haryanto <stevenharyanto@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2014 by Steven Haryanto.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut
