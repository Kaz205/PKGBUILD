# provides.pl
##
# Script for printing out a provides list of every CPAN distribution
# that is bundled with perl.
#
# Justin Davis <jrcd83@gmail.com>

use warnings 'FATAL' => 'all';
use strict;

package Common;

sub evalver
{
    my ($path, $mod) = @_;
    $mod ||= "";

    open my $fh, '<', $path or die "open $path: $!";

    while (<$fh>) {
        next unless /\s*(?:\$${mod}::|\$)VERSION\s*=\s*(.+)/;
        my $ver = eval $1;
        return $ver unless $@;
        warn qq{$path:$. bad version string "$ver"\n};
    }

    close $fh;
    return undef;
}

#-----------------------------------------------------------------------------

package Dists;

sub maindistfile
{
    my ($dist, $dir) = @_;

    # libpath is the modern style, installing modules under lib/
    # with dirs matching the name components.
    my $libpath = join q{/}, 'lib', split /-/, "${dist}.pm";

    # dumbpath is an old style where there's no subdirs and just
    # a .pm file.
    my $dumbpath = $dist;
    $dumbpath =~ s/\A.+-//;
    $dumbpath .= ".pm";

    my @paths = ($libpath, $dumbpath);
    # Some modules (with simple names like XSLoader, lib, etc) are
    # generated by Makefile.PL. Search through their generating code.
    push @paths, "${dist}_pm.PL" if $dist =~ tr/-/-/ == 0;

    for my $path (map { "$dir/$_" } @paths) { return $path if -f $path; }
    return undef;
}

sub module_ver
{
    my ($dist, $dir) = @_;

    my $path = maindistfile($dist, $dir) or return undef;

    my $mod = $dist;
    $mod =~ s/-/::/g;
    my $ver = Common::evalver($path, $mod);
    unless ($ver) {
        warn "failed to find version in module file for $dist\n";
        return undef;
    }

    return $ver;
}

sub changelog_ver
{
    my ($dist, $dir) = @_;

    my $path;
    for my $tmp (glob "$dir/{Changes,ChangeLog}") {
        if (-f $tmp) { $path = $tmp; last; }
    }
    return undef unless $path;

    open my $fh, '<', $path or die "open: $!";
    while (<$fh>) {
        return $1 if /\A\s*(?:$dist[ \t]*)?([0-9._]+)/;
        return $1 if /\A\s*version\s+([0-9._]+)/i;
    }
    close $fh;

    return undef;
}

# for some reason podlators has a VERSION file with perl code in it
sub verfile_ver
{
    my ($dist, $dir) = @_;

    my $path = "$dir/VERSION";
    return undef unless -f $path; # no warning, only podlaters has it

    return Common::evalver($path);
}

# scans a directory full of nicely separated dist. directories.
sub scan_distroot
{
    my ($distroot) = @_;
    opendir my $cpand, "$distroot" or die "failed to open $distroot";
    my @dists = grep { !/^\./ && -d "$distroot/$_" } readdir $cpand;
    closedir $cpand;

    my @found;
    for my $dist (@dists) {
        my $distdir = "$distroot/$dist";
        my $ver = (module_ver($dist, $distdir)
                   || changelog_ver($dist, $distdir)
                   || verfile_ver($dist, $distdir));

        if ($ver) { push @found, [ $dist, $ver ]; }
        else { warn "failed to find version for $dist\n"; }
    }
    return @found;
}

sub find
{
    my ($srcdir) = @_;
    return map { scan_distroot($_) } glob "$srcdir/{cpan,dist}";
}

#-----------------------------------------------------------------------------

package Modules;

use HTTP::Tiny qw();
use File::Find qw();
use File::stat;

*findfile = *File::Find::find;

sub cpan_provider
{
    my ($module) = @_;
    my $url = "http://cpanmetadb.appspot.com/v1.0/package/$module";
    my $http = HTTP::Tiny->new;
    my $resp = $http->get($url);
    return undef unless $resp->{'success'};

    my ($cpanpath) = $resp->{'content'} =~ /^distfile: (.*)$/m
        or return undef;

    my $dist = $cpanpath;
    $dist =~ s{\A.+/}{};    # remove author directory
    $dist =~ s{-[^-]+\z}{}; # remove version and extension
    return ($dist eq 'perl' ? undef : $dist);
}

sub find
{
    my ($srcdir) = @_;
    my $libdir = "$srcdir/lib/";
    die "failed to find $libdir directory" unless -d $libdir;

    # Find only the module files that have not changed since perl
    # was extracted. We don't want the files perl just recently
    # installed into lib/. We processed those already.
    my @modfiles;
    my $finder = sub {
        return unless /[.]pm\z/;
        push @modfiles, $_;
    };
    findfile({ 'no_chdir' => 1, 'wanted' => $finder }, $libdir);

    # First we have to find what the oldest ctime actually is.
    my $oldest = time;
    @modfiles = map {
        my $modfile = $_;
        my $ctime = (stat $modfile)->ctime;
        $oldest = $ctime if $ctime < $oldest;
        [ $modfile, $ctime ]; # save ctime for later
    } @modfiles;

    # Then we filter out any file that was created more than a
    # few seconds after that. Process the rest.
    my @mods;
    for my $modfile (@modfiles) {
        my ($mod, $ctime) = @$modfile;
        next if $ctime - $oldest > 5; # ignore newer files

        my $path = $mod;
        $mod =~ s{[.]pm\z}{};
        $mod =~ s{\A$libdir}{};
        $mod =~ s{/}{::}g;

        my $ver = Common::evalver($path) || q{};
        push @mods, [ $mod, $ver ];
    }

    # Convert modules names to the dist names who provide them.
    my %seen;
    my @dists;
    for my $modref (@mods) {
        my ($mod, $ver) = @$modref;
        my $dist = cpan_provider($mod) or next; # filter out core modules
        next if $seen{$dist}++;                 # avoid duplicate dists
        push @dists, [ $dist, $ver ];
    }
    return @dists;
}

#-----------------------------------------------------------------------------

package Dist2Pkg;

sub name
{
    my ($name) = @_;
    my $orig = $name;

    # Package names should be lowercase and consist of alphanumeric
    # characters only (and hyphens!)...
    $name =~ tr/A-Z/a-z/;
    $name =~ tr/_+/-/; # _ and +'s converted to - (ie Tabbed-Text+Wrap)
    $name =~ tr/-a-z0-9+//cd; # Delete all other chars.
    $name =~ tr/-/-/s;

    # Delete leading or trailing hyphens...
    $name =~ s/\A-|-\z//g;

    die qq{Dist. name '$orig' completely violates packaging standards}
        unless $name;

    return "perl-$name";
}

sub version
{
    my ($version) = @_;

    # Package versions should be numbers and decimal points only...
    $version =~ tr/-/./;
    $version =~ tr/_0-9.-//cd;

    # Remove developer versions because pacman has no special logic
    # to compare them to regular versions like perl does.
    $version =~ s/_[^_]+\z//;

    $version =~ tr/_//d;  # delete other underscores
    $version =~ tr/././s; # only one period at a time
    $version =~ s/\A[.]|[.]\z//g; # shouldn't start or stop with a period

    return $version;
}

#-----------------------------------------------------------------------------

package main;

my $perldir = shift or die "Usage: $0 [path to perl source directory]\n";
die "$perldir is not a valid directory." unless -d $perldir;

my @dists = sort { $a->[0] cmp $b->[0] }
    (Dists::find($perldir), Modules::find($perldir));

for my $dist (@dists) {
    my ($name, $ver) = @$dist;
    $name = Dist2Pkg::name($name);
    $ver  = Dist2Pkg::version($ver);
    print "$name=$ver\n";
}
