package Bio::Graphics::Browser2::DataLoader::useq;

# $Id$
use strict;
use base 'Bio::Graphics::Browser2::DataLoader';
our $big_support = 0;
eval {
    use Bio::DB::BigFile;
    $big_support = 1;
};
our $useq_support = 0;
eval {
    use Bio::DB::USeq;
    $useq_support = 1;
};
use File::Spec;

sub new {
    my $class = shift;
    my $self  = $class->SUPER::new(@_);
    $self->{default_track_name} = 'track000';
    $self;
}

sub default_track_name {
    my $self = shift;
    return $self->{default_track_name}++;
}

sub find_paths {
    my $self = shift;
    
    # looking for a non-executable jar file that may not be in env path
    # so hard code likely paths, taking into account known Virtual Machines
    my @paths = qw(/usr /usr/local /opt /opt/gbrowse /data /data/opt /Applications);
    push @paths, split ':', $ENV{PATH};
    
    my ($USeq2UCSCBig, $bigPath, $java);
    foreach my $p (@paths) {
        unless ($USeq2UCSCBig) {
            my $path = File::Spec->catdir($p, 'USeq*');
            foreach my $candidate (reverse glob($path)) {
                # we reverse the glob results to ensure we find the latest 
                # version if multiple installed, eg USeq_8.4.4 before USeq_8.0.9
                my $app = File::Spec->catdir($candidate, 'Apps', 'USeq2UCSCBig');
                if (-e $app) {
                    $USeq2UCSCBig = $app;
                }
            }
        }
        
        unless ($bigPath) {
            # we need the bin path to both converter utilities
            my $w2bw = File::Spec->catdir($p, 'wigToBigWig');
            my $b2bb = File::Spec->catdir($p, 'bedToBigBed');
            if ( (-e $w2bw && -x _ ) and
                 (-e $b2bb && -x _ ) ) {
                $bigPath = $p;
            }
        }
        
        unless ($java) {
            my $path = File::Spec->catdir($p, 'java');
            $java = $path if (-e $path && -x _ );
        }
        
        last if $USeq2UCSCBig && $bigPath && $java;
    }
    
    return "USeq package from http://useq.sourceforge.net cannot be found for conversion." 
        unless $USeq2UCSCBig;
    return "Utilities wigToBigWig and bedToBigBed cannot be found for conversion." 
        unless $bigPath;
    return "Java 1.6+ cannot be found for conversion." unless $java;
    
    $self->{USeq2UCSCBig} = $USeq2UCSCBig;
    $self->{bigPath}      = $bigPath;
    $self->{java}         = $java;
    return;
}


sub load {
    my $self                = shift;
    my ($initial_lines,$fh) = @_;
    
    $self->flag_busy(1);
    eval {
    $self->open_conf;
    $self->set_status('starting load');
    
    mkdir $self->sources_path or die $!;
    $self->{useq} = File::Spec->catfile($self->sources_path,$self->track_name);
    my $source_file = IO::File->new($self->{useq},'>');

    warn "sourcefile=$self->{useq}";

    $self->start_load;

    $self->set_status('load data');
    my $bytes_loaded = 0;
    foreach (@$initial_lines) {
        $source_file->print($_);
        $bytes_loaded += length $_;
    }

    my $buffer;
    while ((my $bytes = read($fh,$buffer,8192) > 0)) {
        $source_file->print($buffer);
        $bytes_loaded += length $ buffer;
        $self->set_status("loaded $bytes_loaded bytes") if $bytes++ % 10000;
    }
    $source_file->close();
    
    $self->finish_load;
    $self->close_conf;
    $self->set_processing_complete;
    };

    $self->flag_busy(0);
    die $@ if $@;
    return $self->tracks;
}

sub finish_load {
    my $self = shift;
    
    # check first for Bio::DB::USeq support
    my $useq;
    if ($useq_support) {
        $useq = Bio::DB::USeq->new(-file => $self->{useq});
    };
    if ($useq) {
        $self->finish_useq_load($useq);
        return;
    }
    # if that fails, resort to bigfile conversion and support
    die "Bio::DB::USeq or supplementary Bio::DB::BigFile support is not installed for USeq files" 
        unless $big_support;
    my $error = $self->find_paths;
    die "Bio::DB::USeq is not installed. $error" if $error;
    $self->convert_useq;
    
    my @bw;
    my @bb;
    my $path = $self->sources_path . "/*";
    foreach my $f (glob($path)) {
        push @bw, $f if $f =~ /\.bw$/;
        push @bb, $f if $f =~ /\.bb$/;
    }
    
    if (scalar @bb == 1) {
        $self->finish_bigbed_load(@bb);
    }
    elsif (scalar @bw == 1) {
        $self->finish_bigwig_load(@bw);
    }
    elsif (scalar @bw == 2) {
        $self->finish_stranded_bigwig_load(@bw);
    }
}

sub convert_useq {
    my $self = shift;
    
    $self->set_status('Converting with USeq2UCSCBig');
    my $java    = $self->{java};
    my $app     = $self->{USeq2UCSCBig};
    my $bigPath = $self->{bigPath};
    my $useq    = $self->{useq};
    local $SIG{CHLD} = 'DEFAULT';
    my $fh;
    open $fh, "($java -jar '$app' -d '$bigPath' -u '$useq' && echo 'success') 2>&1 |";
    my @lines = <$fh>;
    close $fh;
    unless ($lines[-1] =~ /success/) {
        die "USEQ CONVERSION ERROR: @lines";
    }
    unlink $useq; # no longer need the original file
    unlink "$useq.chromLengths" if -e "$useq.chromLengths";
    unlink "$useq.wig" if -e "$useq.wig";
}

sub finish_useq_load {
    my $self = shift;
    my $useq = shift;
    
    my $loadid     = $self->loadid;
    $self->set_status('writing configuration for useq');
    my $conf       = $self->conf_fh;
    my $dbid       = $self->new_track_label;
    my $file       = $self->{useq};
    my $name       = $self->track_name;
    
    print $conf <<END;
[$dbid:database]
db_adaptor    = Bio::DB::USeq
db_args       = -file '$file'

#>>>>>>>>>> cut here <<<<<<<<
[$dbid]
database = $dbid
END
    ;
    
    # useq information
    my $citation    = $useq->attribute('description') || undef;
    my $color       = $useq->attribute('initialColor');
    unless (defined $color) {
        my @COLORS = qw(blue red orange brown mauve green cyan);
        $color = $COLORS[rand @COLORS];
    }   
    
    # determine glyph type
    if ($useq->type =~ /graph/i) {
        my ($feature, $glyph, $graph_type);
        my $graphStyle = $useq->attribute('initialGraphStyle');
        if ($graphStyle =~ /bar/i) {
            $feature    = 'wiggle:1000';
            $glyph      = 'wiggle_xyplot';
            $graph_type = 'histogram';
        }
        elsif ($graphStyle =~ /stairstep/i) {
            $feature    = 'wiggle:1000';
            $glyph = 'wiggle_xyplot';
            $graph_type = 'histogram';
        }
        elsif ($graphStyle =~ /line/i) {
            $feature    = 'wiggle:1000';
            $glyph = 'wiggle_xyplot';
            $graph_type = 'line';
        }
        elsif ($graphStyle =~ /dot/i) {
            $feature    = 'wiggle:1000';
            $glyph = 'wiggle_xyplot';
            $graph_type = 'points';
        }
        elsif ($graphStyle =~ /min_max_ave/i) {
            $feature    = 'summary';
            $glyph = 'wiggle_whiskers';
        }
        elsif ($graphStyle =~ /heatmap/i) {
            $feature    = 'wiggle:1000';
            $glyph = 'wiggle_density';
        }
        else {
            $feature    = 'wiggle:1000';
            $glyph      = 'wiggle_xyplot';
            $graph_type = 'histogram';
        }
        my $hint = "\n# set feature to 'summary' to use wiggle_whiskers glyph" unless 
            $feature eq 'summary';
        
        my $min = $useq->attribute('initialMinY');
        my $max = $useq->attribute('initialMaxY');
        my $scale;
        if (defined $min and defined $max) {
            $scale = "min_score = $min\nmax_score = $max";
        }
        else {
            $scale = 'autoscale = chromosome';
        }
        my $height = $glyph eq 'wiggle_density' ? 10 : 50;
        
        print $conf <<END;
feature  = $feature$hint
glyph    = $glyph
graph_type = $graph_type
$scale
fgcolor  = black
bgcolor  = $color
height   = $height
END
    }
    else {
        # treat as regions
        print $conf <<END;
feature  = region
glyph    = segments
label density = 50
feature_limit = 500
bump     = fast
stranded = 1
height   = 4
bgcolor  = $color
fgcolor  = $color
END
    }
    
    # final information
    print $conf <<END
key      = $name
citation = $citation
END
}

sub finish_bigbed_load {
    my $self = shift;
    my $bigbed     = shift;
    my @COLORS = qw(blue red orange brown mauve peach 
                    green cyan yellow coral);
    
    my $loadid     = $self->loadid;
    $self->set_status('writing configuration for bigBed');
    my $conf       = $self->conf_fh;
    my $dbid       = $self->new_track_label;
    print $conf <<END;
[$dbid:database]
db_adaptor    = Bio::DB::BigBed
db_args       = -bigbed '$bigbed'

END
    ;
    print $conf "#>>>>>>>>>> cut here <<<<<<<<\n";
    my $color = $COLORS[rand @COLORS];
    my $name = $self->track_name;
    
    print $conf <<END
[$dbid]
database = $dbid
feature  = region
glyph    = segments
label density = 50
feature_limit = 500
bump     = fast
stranded = 1
height   = 4
bgcolor  = $color
fgcolor  = $color
key      = $name segments
description = 

[$dbid\_coverage]
database = $dbid
feature  = summary
glyph    = wiggle_whiskers
fgcolor  = black
height   = 50
autoscale = chromosome
key      = $name coverage
description = 

END
;
# We are defining two separate tracks rather than using semantic zoom 
# because of the flexible nature of the bigBed format. It can be used 
# as a Bam substitute where coverage is the best glyph, or it can be used 
# for sparse intervals of interest where segments is the best glyph. 
# Onus is on the user to select the most appropriate one.
}

sub finish_bigwig_load {
    my $self = shift;
    my $bigwig     = shift;
    
    my $loadid     = $self->loadid;
    $self->set_status('writing configuration for bigWig');
    my $conf       = $self->conf_fh;
    my $dbid       = $self->new_track_label;
    print $conf <<END;
[$dbid:database]
db_adaptor    = Bio::DB::BigWig
db_args       = -bigwig '$bigwig'

END
    ;
    print $conf "#>>>>>>>>>> cut here <<<<<<<<\n";
    my $name = $self->track_name;
    
    print $conf <<END
[$dbid]
database = $dbid
feature  = summary
glyph    = wiggle_whiskers
fgcolor  = black
height   = 50
autoscale = chromosome
key      = $name
description = 

END
;

}

sub finish_stranded_bigwig_load {
    my $self = shift;
    
    $self->set_status('preparing db for BigWigSet');
    
    my ($minus, $plus);
    foreach (@_) {
        my (undef, undef, $file) = File::Spec->splitpath($_);
        $file =~ s/\.bw$//;
        $plus  = $file if $file =~ /Plus$/;
        $minus = $file if $file =~ /Minus$/;
    }
    
    my $name = $self->track_name;
    my $path  = $self->sources_path;
    my $index = File::Spec->catdir($path, 'metadata.txt');
    open my $fh, ">", $index or return;
    
    print $fh <<END
[$plus\.bw]
primary_tag  = $name
display_name = $plus
strand       = plus 

[$minus\.bw]
primary_tag  = $name
display_name = $minus
strand       = minus
END
;
    close $fh;
    
    my $loadid     = $self->loadid;
    my $conf       = $self->conf_fh;
    my $dbid       = $self->new_track_label;
    print $conf <<END;
[$dbid:database]
db_adaptor    = Bio::DB::BigWigSet
db_args       = -dir '$path'
                -feature_type summary

#>>>>>>>>>> cut here <<<<<<<<
    
[$dbid]
database = $dbid
feature  = $name
subtrack select = Strand tag_value strand
subtrack table  = :Plus plus;
                  :Minus minus;
glyph    = wiggle_xyplot
height   = 50
bgcolor         = blue
fgcolor         = black
autoscale = chromosome
key      = $name
description = 

END
;
}

1;
__END__

=head1 NAME

Bio::Graphics::Browser2::DataLoader::useq

=head1 DESCRIPTION

A data loader for the USeq archive, recognized by the file extension ".useq". 
See L<http://useq.sourceforge.net/useqArchiveFormat.html>
for information regarding the file format. Briefly, this format can store either 
genomic intervals with or without text and/or scores, or quantitative scores 
along a chromosome (point data). 

The uploader will preferentially use the native Bio::DB::USeq adaptor. It will 
set up either a wiggle or segment glyph, depending upon content. 

If the Bio::DB::USeq adaptor cannot be used, but UCSC big file support is 
installed, then the USeq file is converted to either a UCSC BigBed or BigWig 
format, depending upon the file contents. Stranded point data may be converted 
into two BigWig files, each for the Plus and Minus strand. Configuration files 
are generated as appropriate for the converted files. 

=head1 SETUP

The native useq database adaptor Bio::DB::USeq can be obtained from CPAN.

For converting the USeq archive, the USeq package (L<http://useq.sourceforge.net>) must 
be installed in a globally accessible path. This location is searched upon 
initiation. Common paths to search include "/usr", "/usr/local", "/opt", 
"/opt/gbrowse", "/data", "/data/opt", and "/Applications", in that order. 

The USeq App "USeq2UCSCBig" (a jar file) is used to convert the USeq archive. This 
app requires three binary executables: "java" and the two UCSC utilities "bedToBigBed" 
and "wigToBigWig". These are searched for in the environment $PATH variable. 
The UCSC utilities are available at L<http://hgdownload.cse.ucsc.edu/admin/exe/>. 
The USeq Apps requires Java 1.6+. 

Failure to find the paths for all three will result in failure to process the .useq 
file. 

=head1 AUTHOR

 Timothy J. Parnell, PhD
 Dept of Oncological Sciences
 Huntsman Cancer Institute
 University of Utah
 Salt Lake City, UT, 84112

This package is free software; you can redistribute it and/or modify
it under the terms of the GPL (either version 1, or at your option,
any later version) or the Artistic License 2.0.  

