#!/usr/bin/perl -w

###########################################################################
#
# Prototype pre-renderer of tiles for the new GBrowse.  Based on bits and
# pieces of 'gbrowse_img' and 'Browser.pm', (the 'image_and_map' function)
# incorporated into one standalone script that uses our TiledImagePanel.pm
# module (which is a modification of Bio::Graphics::Panel with essentially
# the same functionality, except using the TiledImage object instead of
# GD::Image, making it possible to render tiles of very large images).
#
# !!! NOTES:
# - Remember that 'arrow.pm' had to be hacked!
# - Load args to this program from a config file?
# - TODO: Make script check for nonexistent/not implemented arguments
#
###########################################################################

use strict;
use Bio::DB::GFF;
use Bio::Graphics;
use Bio::Graphics::Browser;
use Bio::Graphics::Browser::Util;
use GD::SVG;                       # this may be necessary later !!!
use Bio::Graphics::Panel;
use Data::Dumper;
use Carp 'croak','cluck';
use Time::HiRes qw( gettimeofday tv_interval );
use Digest::MD5 qw(md5);
use XML::DOM;
use Fcntl qw( :DEFAULT :flock :seek );

# max number of hardlinks to a single file, minus some margin
use constant MAX_LINKS => 30000;

my $start_time = [gettimeofday];

# --- BEGIN MANUAL PARAMETER SPECIFICATIONS ---
my $rendering_tilewidth = 24000;  # tile width (in pixels) for RENDERING via TiledImage (bigger tiles
                                  # render faster, so we render big chunks, then break them up into pieces)
my $tilewidth_pixels = 1000;      # actual width (in pixels) of tiles for client; the TiledImage tiles get
                                  # broken up into these after rendering; note that it must be true that:
                                  #   $tilewidth_pixels % $tilewidth_pixels_final = 0
                                  # otherwise we will have leftover, unrendered pixels!

my $xmlfile = 'tileinfo.xml';     # XML file name to save settings/etc. to

# default output is to the current directory
my $default_outdir = `pwd`;
chomp $default_outdir;
$default_outdir .= '/';

# try to find a configuration file directory (check the usual suspects)
my $default_confdir;
foreach my $dir (qw [
		     /usr/local/apache2/conf/gbrowse.conf/
		     /usr/local/conf/gbrowse.conf/
		     /etc/httpd/conf/gbrowse.conf/
		     /Library/WebServer/conf/gbrowse.conf/
		    ]) {
  if (-e $dir) {
    $default_confdir = $dir;
    last;
  }
}

my $global_padding = 100; #pixels
# --- END MANUAL PARAMETER SPECIFICATIONS ---

# Parse command line arguments and load configuration data

my %args;
for (my $i = 0; $i < @ARGV; $i++) {
    if (substr($ARGV[$i], 0, 1) eq '-') {  # find command line params...
	$args{$ARGV[$i]} = $ARGV[$i+1];    # ...and save them
    }
}

print_usage() if exists $args{'-?'} or exists $args{'-help'} or exists $args{'--help'};
my $exit_early = 1 if exists $args{'--exit-early'};
my $no_xml = 1 if exists $args{'--no-xml'};
my $render_gridlines = exists $args{'--render-gridlines'} ? 1 : 0;

print
    "-------------------------------------------------------------------------\n",
    " Script was invoked with parameters: @ARGV \n";

# set mode (i.e. what does the user want this script to do?) - note the XML file is ALWAYS output
my ($fill_database, $render_tiles);
if (exists $args{'-m'}) {
    if    ($args{'-m'} == 0) { ($fill_database, $render_tiles) = (1, 1); }
    elsif ($args{'-m'} == 1) { ($fill_database, $render_tiles) = (1, 0); }
    elsif ($args{'-m'} == 2) { ($fill_database, $render_tiles) = (0, 1); }
    elsif ($args{'-m'} == 3) { ($fill_database, $render_tiles) = (0, 0); }
    else                     { die "ERROR: invalid '-m' parameter!\n"; }
} else {
    print " Using default mode (fill database and render tiles)...\n";
    ($fill_database, $render_tiles) = (1, 1);  # defaults
}

print " XML file will NOT be generated...\n" if $no_xml;

my ($verbose);  # these get passed to TiledImage

if (exists $args{'-v'}) {
    if    ($args{'-v'} == 2) { $verbose = 2; }
    elsif ($args{'-v'} == 1) { $verbose = 1; }
    elsif ($args{'-v'} == 0) { $verbose = 0; }
    else                     { die "ERROR: invalid '-v' parameter!\n"; }
} else {
    print " Using default setting: NOT in verbose mode...\n" if $fill_database or $render_tiles;
    $verbose = 0;
}

# do output directory and XML file stuff
my $outdir = $args{'-o'};
unless ($outdir) {
    $outdir = $default_outdir;
    print " Using default output directory (${outdir})...\n" unless !$render_tiles and $no_xml;
}

unless (-e $outdir || !$render_tiles) {
    mkdir $outdir or die "ERROR: cannot make output directory ${outdir}! ($!)\n";
}

# do database '.conf' directory stuff
my $CONF_DIR = $args{'-c'};
if ($CONF_DIR) {
  die "ERROR: cannot access '.conf' directory (${CONF_DIR})!\n" unless -e $CONF_DIR;
} else {
  if ($default_confdir) {
    $CONF_DIR = $default_confdir;
    print " Using a default '.conf' directory (${CONF_DIR})...\n";
  } else {
    die "ERROR: no default '.conf' directory found and you did not provide one explicitly (-c option)... cannot continue!\n";
  }
}

# load stuff from config file
$CONF_DIR = conf_dir($CONF_DIR);
my $CONFIG = open_config($CONF_DIR);  # create Bio::Graphics::Browser configuration object

# if more than one possible source (i.e. more than one '.conf' file in $CONF_DIR) exists,
# the user needs to make a choice
my ($source, @sources) = ($args{'-s'}, $CONFIG->sources);
if (@sources > 1) {
    if ($source) {
	$CONFIG->source($source) or die "ERROR: no such source! (the choices are: @sources)\n";
    }
    else {
	die "ERROR: multiple sources found - you must specify a single source! (the choices are: @sources)\n";
    }
} else {
    $source = $CONFIG->source;
    die "ERROR: no sources that can be loaded from ${CONF_DIR}!\n" if !$source;
}

print " Configuration file directory: ${CONF_DIR}\n";

my $source_name = $CONFIG->setting('description');  # get human-readable description

my $db = open_database($CONFIG);      # create Bio::DB::GFF::Adaptor::<adaptor name> object, where
                                      # <adaptor name> is what is specified in the '.conf' file

print " Source: ${source} (${source_name})\n";

# get landmark info
my $conf = $CONFIG->config;  # a Bio::Graphics::BrowserConfig object, which uses 
                             # the Bio::Graphics::FeatureFile package

my $landmark_name = $args{'-l'};  # for passing to BioGraphics
die "ERROR: you must provide a landmark name!\n" if !$landmark_name;

# note that @segments should always be a 1-element array, since we are forcing only one landmark
# per script execution and we are considering the ENTIRE landmark
#my @segments = $CONFIG->name2segments($landmark_name, $db, 0, 0);  # this should return the range of the entire landmark
my @segments = $db->segment(-name => $landmark_name);
my $segment = $segments[0];

$Data::Dumper::Maxdepth = 2;
print "segs: " . Dumper(@segments) . "\n";

die "ERROR: problem loading landmark! (are you sure the name is correct? you provided: ${landmark_name})\n"
    if !$segment;

# get landmark dimensions
my ($landmark_start, $landmark_end, $landmark_length) = ($segment->start, $segment->end, $segment->length);
my $landmark = "${landmark_name}:${landmark_start}..${landmark_end}";

print
    " Landmark: ${landmark} (${source_name})\n",
    " Landmark length: ${landmark_length} bases\n";

# NB: the following paths are landmark specific (TODO: when we implement looping over multiple
# landmarks, the following will have to be in the loop body)

my $outdir_tiles = "${outdir}/tiles/";
unless (-e $outdir_tiles || !$render_tiles) {
    mkdir $outdir_tiles or die "ERROR: cannot make tile output directory ${outdir_tiles}! ($!)\n";
}
$outdir_tiles .= "${landmark_name}/";  # append landmark-specific subdir
unless (-e $outdir_tiles || !$render_tiles) {
    mkdir $outdir_tiles or die "ERROR: cannot make tile output directory ${outdir_tiles}! ($!)\n";
}
print " Output directory: ${outdir}\n" unless !$render_tiles and $no_xml;

my $html_outdir_tiles = "tiles/${landmark_name}";

print
    "-------------------------------------------------------------------------\n";

my @track_labels = ('ruler', $CONFIG->labels); # get all the labels (i.e. tracks) possible, add the genomic ruler track
my $num_tracks = @track_labels; 

print
    " Numbered track labels (from '.conf' file):\n",
    " ";
for (my $num = 1; $num <= $num_tracks; $num++) {
    print "  ($num) $track_labels[$num-1]";  # subtract 1 for 0-based array indexing
}
print "\n";

# get the zoom levels from the '.conf' file
my @zooms_from_config = split(" ", $CONFIG->setting('zoom levels'));

# parse zoom levels into an internal format, which is an array of references where each reference
# is to a sub-array that lists:
#  - the name of the zoom level,
#  - the resolution in bases per 1000 pixels, and
#  - units to use for major tick marks in the genomic ruler (see %UNITS hack in 'arrow.pm'!!!)
# and also into a hash form, so we can use the first of the above as a key to get the latter two values
my (@zoom_levels, %zoom_levels);
my ($unit, $suffix, $divisor) = ('bp', '', '1');
my %suffices = (1e3 => 'k', 1e6 => 'M', 1e9 => 'G', 1e12 => 'T', 1e15 => 'P', 1e18 => 'E');  # should be enough

foreach my $zoom (sort {$a <=> $b} @zooms_from_config) {
    last if $zoom >= $landmark_length;  # there's no point in having zoom levels this large
    ($suffix, $divisor) = ('', 1);
    my @sorted_keys = sort {$a <=> $b} keys %suffices;
    for (my $i = 0; $zoom >= $sorted_keys[$i]; $i++) {  # look up which units to use in the suffix
	$divisor = $sorted_keys[$i];
	$suffix = $suffices{$divisor};
    }
    
    my $zoom_level_name = $zoom / $divisor . $suffix . $unit;
    push @zoom_levels, [$zoom_level_name, $zoom, $suffix];

    $zoom_levels{$zoom_level_name} = [$zoom, $suffix];
}

push @zoom_levels, ['entire_landmark', $landmark_length, $suffix];  # add zoom level for viewing the whole landmark
$zoom_levels{'entire_landmark'} = [$landmark_length, $suffix];

my $default_zoom_level_name = $zoom_levels[-1][0];    # default to the largest zoom level available
my @zoom_level_names = map { $_->[0] } @zoom_levels;  # get our processed results for SORTED output to user

my $num_zooms = @zoom_level_names;
print
    " Numbered zoom levels:\n",
    " ";
for (my $num = 1; $num <= $num_zooms; $num++) {
    print "  ($num) $zoom_level_names[$num-1]";
}
print "\n";

print
    " There are $num_tracks tracks, $num_zooms zoom levels total\n",
    "-------------------------------------------------------------------------\n";

# threshold of the average number of features per tile
# above which we won't print labels
my $label_thresh = $args{'-p'} || 50;

# threshold of the average number of features per tile
# above which we switch to a density histogram
my $hist_thresh = $args{'-d'} || 300;

# build a hash of hashes of tuples (arrays) storing the range of tiles that are going to be printed for
# each track and zoom level combination; initialize this to print everything, which may be overridden
# later if user sets the '-r' option(s); hash is keyed by track name and zoom level name as they appear
# in @track_labels and @zoom_level_names
my %tile_ranges_to_render;
foreach my $track (@track_labels) {                    # go through each track...
    foreach my $zoom_level_name (@zoom_level_names) {  # ...and each zoom level, save maximum range of tiles
        $tile_ranges_to_render{$track}{$zoom_level_name} = [1, ceiling($landmark_length / ($zoom_levels{$zoom_level_name}->[0] * ($tilewidth_pixels / 1000)))];
    }
}

my $print_tile_nums = 1 if exists $args{'--print-tile-nums'};

my %print_track_and_zoom;  # keeps track of any tracks and zoom levels that we should flat-out ignore;
                           # keys to the hash are as they appear in @track_labels and @zoom_level_names
if (exists $args{'-r'}) {
    my @subsets = split(',', $args{'-r'});

    if (@subsets == 0) {
	die "ERROR: you did not specify any subsets after the '-r' parameter!\n";
    }

    foreach my $subset (@subsets) {
	unless ($subset =~ /t(\d+)z(\d+)r(\d+)-(\d+)/) {
	    die "ERROR: malformed subset specification ($subset) after the '-r' parameter!\n";
	}
	my ($track_num, $zoom_level_num, $first_tile, $last_tile) = ($1, $2, $3, $4);
	my ($max_lower_bound, $max_upper_bound) =
	    ($tile_ranges_to_render{$track_labels[$track_num-1]}{$zoom_level_names[$zoom_level_num-1]}->[0],
	     $tile_ranges_to_render{$track_labels[$track_num-1]}{$zoom_level_names[$zoom_level_num-1]}->[1]);
	
	# do some correctness checks to prevent trouble
	die "ERROR: you can't have an upper bound that is smaller than the lower bound in your range specification ($subset)!\n"
	    if ($last_tile < $first_tile);
	die "ERROR: track number in subset specification ($subset) is out of range! (tracks are numbered from 1 to $num_tracks)\n"
	    if ( ($track_num > $num_tracks) || ($track_num < 1) );
	die "ERROR: zoom level number in subset specification ($subset) is out of range! (tracks are numbered from 1 to $num_zooms)\n"
	    if ( ($zoom_level_num > $num_zooms) || ($zoom_level_num < 1) );
	die
	    "ERROR: tile number range in subset specification ($subset) is out of max allowed range ",
	    "(which is $max_lower_bound to $max_upper_bound tiles for this track and zoom level)!\n"
	    if ( ($first_tile < $max_lower_bound) || ($last_tile > $max_upper_bound) );
	
	# record that we are printing the subset
	$print_track_and_zoom{$track_labels[$track_num-1]}{$zoom_level_names[$zoom_level_num-1]} = 1;
	
	# record the range that we are printing (overwrite old range)
	$tile_ranges_to_render{$track_labels[$track_num-1]}{$zoom_level_names[$zoom_level_num-1]}->[0] = $first_tile;
	$tile_ranges_to_render{$track_labels[$track_num-1]}{$zoom_level_names[$zoom_level_num-1]}->[1] = $last_tile;
    }
} elsif (exists $args{'-t'}) {
    my @tracklist = map {$_ - 1} split(",", $args{'-t'});
    foreach my $zoom_level_name (@zoom_level_names) {
        foreach my $track (@tracklist) {
            $print_track_and_zoom{$track_labels[$track]}{$zoom_level_name} = 1;
        }
    }
} else {
    # no subset specified, so we print EVERYTHING
    foreach my $track (@track_labels) {
	foreach my $zoom_level_name (@zoom_level_names) {
	    $print_track_and_zoom{$track}{$zoom_level_name} = 1;
	}
    }
}

if ($print_tile_nums) {  # output track names, zoom level names, and tile ranges
    if (exists $args{'-r'}) {
	print " The script will be applied to the following tiles:\n";
    } elsif (exists $args{'-t'}) {
        print " The script will be applied to track " . $args{'-t'} . ": " . $track_labels[$args{'-t'} - 1] . "\n";
    } else {
	print " The script will be applied to ALL tiles:\n";
    }
    my $track_num = 1;
    foreach my $track (@track_labels) {
	my $zoom_level_num = 1;
	foreach my $zoom_level_name (@zoom_level_names) {
	    print
		"   track $track_num ($track) zoomlevel $zoom_level_num (", $zoom_levels{$zoom_level_name}->[0], ")",
		" firsttile ", $tile_ranges_to_render{$track}{$zoom_level_name}->[0],
	        " lasttile ", $tile_ranges_to_render{$track}{$zoom_level_name}->[1], "\n"
		if $print_track_and_zoom{$track}{$zoom_level_name};
	    $zoom_level_num++;
	}
	$track_num++;
    }
    print "-------------------------------------------------------------------------\n";
}

exit if $exit_early;  # bail out if the user just wanted results of parsing the '.conf' file

# iterate over tracks (i.e. labels)
for (my $label_num = 0; $label_num < @track_labels; $label_num++)
{
    my $label = ($track_labels[$label_num]);

    next unless $print_track_and_zoom{$label};

    my $image_height;
    my $track_name;
    my @feature_types;
    my @features;

    if ($label ne 'ruler') {
        my %track_properties = $conf->style($label);
        $track_name = $track_properties{"-key"};

        # get feature types in form suitable for Bio::DB::GFF
        @feature_types = $conf->label2type($label, $landmark_length);
        @features = $segment->features(-type => \@feature_types)
          if (@feature_types);
    }

    # sometimes the track name is unspecified, so use the label instead
    $track_name = $label unless $track_name;

    warn "=== GENERATING TRACK $label ($track_name)... ===\n" if $verbose;

    my $lang = $CONFIG->language;

    # iterate over zoom levels
    my $zoom_level_num = 0;
    foreach my $zoom_level (@zoom_levels) {
    	$zoom_level_num++;
	my $zoom_level_name = $zoom_level->[0];

        next unless $print_track_and_zoom{$label}{$zoom_level_name};  # skip if not printing

        my $tilewidth_bases = $zoom_level->[1] * ($tilewidth_pixels / 1000);
	my $num_tiles = ceiling($landmark_length / $tilewidth_bases) + 1;  # give it an extra tile for a temp half-assed fix
        my $image_width = ($landmark_length / $zoom_level->[1]) * 1000; # in pixels

	# I'm really not sure how palatable setting this option here will be... but we can't
	# set it any earlier...
	$CONFIG->width($image_width);  # set image width (in pixels)

        warn "----- GENERATING ZOOM LEVEL ${zoom_level_name}... ----- " . tv_interval($start_time) . "\n" if $verbose;

	# create the track that we will need

	# replace spaces and slashes in track name with underscores for writing file path prefixes
	my $track_name_underscores = $track_name;
	$track_name_underscores =~ s/[ \/]/_/g;

	# make output directories
	my $current_outdir = "${outdir_tiles}/${track_name_underscores}";
	unless (-e $current_outdir || !$render_tiles) {
	    mkdir $current_outdir or die "ERROR: problem making output directory ${current_outdir}! ($!)\n";
	}
	my $html_current_outdir = "${html_outdir_tiles}/${track_name_underscores}" unless $no_xml;

	$current_outdir = "${current_outdir}/${zoom_level_name}/";
	unless (-e $current_outdir || !$render_tiles) {
	    mkdir $current_outdir or die "ERROR: problem making output directory ${current_outdir} ($!)\n";
	}

	$html_current_outdir = "${html_current_outdir}/${zoom_level_name}/" unless $no_xml;

	my $tile_prefix = "${current_outdir}/tile";
        $tile_prefix = "${current_outdir}/rulertile"
            if $track_name eq 'ruler';

        my @argv = (-start => $landmark_start,
		    -end => $landmark_end,
		    -stop => $landmark_end,  # backward compatability with old BioPerl
                    -bgcolor => "",
		    -width => $image_width,
		    -grid => $render_gridlines,
		    -gridcolor => 'linen',
		    -key_style => 'none',  # we don't want no key, client will render that for us
		    -empty_tracks => $conf->setting(general => 'empty_tracks') || 'key',
		    -pad_top => 0,  # padding is probably 0 by default, but we will specify just in case
		    -pad_left => 0,
		    -pad_right => $tilewidth_pixels,  # to accomodate overrun of elements in "last" tile
		    -image_class => 'GD'
	      );

        my $panel = Bio::Graphics::Panel->new(@argv);

        # we use a dummy gd object to set up the main panel palette
        $panel->{gd} = GD::Image->new(1, 1);
        setupPalette($panel);

        my $track;
        my $is_global = 0;
        my $is_hist = 0;
        my @track_settings = ($conf->default_style, $conf->i18n_style($label, $lang, $landmark_length));
        if ($track_name eq 'ruler') {
            my ($major, $minor) = $panel->ticks;
            @track_settings = (-glyph => 'arrow',
			       # double-headed arrow:
			       -double => 1,

			       # draw major and minor ticks:
			       -tick => 2,

			       # if we ever want unit labels, we may 
                               # want to bring this back into action...!!!
			       #-units => $conf->setting(general => 'units') || '',
			       -unit_label => '',

			       # if we ever want unit dividers to be
                               # loaded from $conf, we'll have to use
			       # the commented-out option below, 
                               # instead of hardcoding...!!!
			       #-unit_divider => $conf->setting(general => 'unit_divider') || 1,
			       #-unit_divider => 1,

			       # forcing the proper unit use for
                               # major tick marks
			       -units_forced => $zoom_level->[2],
                               -major_interval => $major,
                               -minor_interval => $minor,
			      );
            $track = $panel->add_track($segment, @track_settings);
            $is_global = 1;
        } elsif ($conf->setting($label=>'global feature')) {
            $track = $panel->add_track($segment, @track_settings);
            $is_global = 1;
        } elsif (($#features  / $num_tiles) > $hist_thresh) {
            # generate a feature density histogram
            my @bins;
            my $binsize = $tilewidth_bases / 100;
            foreach my $feat (@features) {
                foreach my $bin (($feat->start / $binsize)
                                 ..($feat->end / $binsize)) {
                    $bins[$bin]++;
                }
            }
            my @histfeatures;
            foreach my $bin (0..$#bins) {
                next unless $bins[$bin];
                push @histfeatures, new Bio::Graphics::Feature ( 
                    -start        => $bin * $binsize, 
                    -end          => ($bin + 1) * $binsize - 1,
                    -strand       => 1, 
                    -primary      => 'bin',
                    -score        => $bins[$bin]
                    );
            }

            my $bigFeature = new Bio::Graphics::Feature ( 
                    -start        => $landmark_start, 
                    -end          => $landmark_end,
                    -strand       => 1, 
                    -primary      => 'binAgg',
                    -segments     => \@histfeatures
                    );

            $track = $panel->add_track([$bigFeature],
                                       @track_settings,
                                       -glyph => "xyplot",
                                       -graph_type=>"boxes",
                                       -scale=>"both",
                                       -height=>200,
                                       -bump => 0);
            $is_hist = 1;
        } else {
            $track = $panel->add_track(@track_settings);

            # NOTE: $track is a Bio::Graphics::Glyph::track object

	  # go through all the features and add them (but only if we have features)
	  if (@features) {
            foreach my $feature (@features) {
	      warn " adding feature ${feature}...\n" if $verbose == 2;
	      $track->add_feature($feature);
	    }

            # if the average number of features per tile is
            # less than $label_thresh, we print labels
            if (($#features  / $num_tiles) < $label_thresh) {
                $track->configure(-bump => 1, -label => 1, -description => 1);
            } else {
                $track->configure(-bump => 1, -label => 0, -description => 0);
            }
	  }
	}

        warn "track is set up: " . tv_interval($start_time) . "\n" if ($render_tiles && $verbose);

        # get image height, now that the panel is fully constructed
        $image_height = $panel->height;

        warn "track is laid out: " . tv_interval($start_time) . "\n" if ($render_tiles && ($verbose >= 1));

        my $blankHtml;
        my $linkCount = 0;
        my $tile_callback = sub {
            my ($tile_prefix, $tile_num, $tileURL, $tile_boxes) = @_;

            if ($linkCount > MAX_LINKS) {
                undef $blankHtml;
                $linkCount = 0;
            }

            my $outhtml = "${tile_prefix}${tile_num}.html";
            if (!$is_global && !$is_hist && !defined($tile_boxes)) {
                if (defined($blankHtml)) {
                    link $blankHtml, $outhtml
                        || die "could not link blank tile: $!\n";
                    $linkCount++;
                    return;
                } else {
                    $blankHtml = $outhtml;
                }
            }

            $tile_boxes = () if ($is_global || $is_hist);

            writeHTML($outhtml, $tile_num, $tilewidth_pixels, $image_height,
                      $label_num - 1, $tileURL, $tile_boxes);
        };
        
        $tile_callback = sub {} if $track_name eq 'ruler';

        if ($render_tiles) {
            renderTileRange(
                # NB change from 1-based to 0-based coords
                $tile_ranges_to_render{$label}{$zoom_level_name}->[0] - 1,
                $tile_ranges_to_render{$label}{$zoom_level_name}->[1] - 1,
                $tilewidth_pixels,
                $rendering_tilewidth,
                $tile_prefix,
                $is_global,
                $panel,
                $track,
                $image_height,
                {@argv},
                \@track_settings,
                $html_current_outdir || "",
                $tile_callback
                );
	}
        $panel->finished();
        $panel = undef;

        unless ($no_xml) {
            my $xml = new IO::File;
            $xml->open("${outdir}/${xmlfile}", O_RDWR | O_CREAT)
                or die "ERROR: cannot open '${outdir}/${xmlfile}' ($!)\n";
            flock($xml, LOCK_EX)
                or die "couldn't lock XML: $!";
            my $doc;
            if (-z "${outdir}/${xmlfile}") {
                $doc = initXml($default_zoom_level_name, $source_name, 
                                $landmark_start, $landmark_end, $landmark_name,
                                $tilewidth_pixels, $source);
            } else {
                my $parser = new XML::DOM::Parser;
                $doc = $parser->parse($xml) or die "couldn't parse XML: $!";
            }
            my $root = $doc->getDocumentElement;
            if ($label eq 'ruler') {
                setAtts(ensureChild($root, "ruler"),
                        "tiledir" => "${html_outdir_tiles}/ruler/",
                        "height" => $image_height);
            } else {
                my @tracks = ensureChild($root, "tracks");
                my @this_track = ensureChild($tracks[0], "track",
                                             "name" => $track_name);
                my @this_zoom = ensureChild($this_track[0], "zoomlevel",
                                            "name" => $zoom_level_name);
                setAtts($this_zoom[0],
                        "tileprefix" => $html_current_outdir,
                        "name" => $zoom_level_name,
                        "unitspertile" => $tilewidth_bases,
                        "height" => $image_height,
                        "numtiles" => $num_tiles);
            }
            $xml->truncate(0) or die "couldn't truncate XML: $!";
            $xml->seek(0, SEEK_SET) or die "couldn't seek to XML start: $!";
            $xml->print($doc->toString . "\n") or die "couldn't write XML: $!";
            $xml->close or die "couldn't close XML: $!";
        }

        warn "tiles for track $label zoom $zoom_level_name rendered: " . tv_interval($start_time) . "\n" if ($render_tiles && ($verbose >= 1));

    } # ends loop iterating through zoom levels
}  # ends the 'for' loop iterating through @track_labels

# checks that the given parent element has at least one
# child with the given tag name and (optional) attribute values.
# if there's no such child, creates one.
sub ensureChild {
    my ($parent, $tag, %atts) = @_;
    my $filter = sub {
        my $node = shift;
        foreach my $key (keys %atts) {
            return 0 if $node->getAttribute($key) ne $atts{$key};
        }
        return 1;
    };
    my @children = grep &$filter($_), $parent->getElementsByTagName($tag);
    return @children if @children;
    my $child = $parent->appendChild($parent->getOwnerDocument->createElement($tag));
    setAtts($child, %atts);
    return $child;
}

# sets multiple attributes on a given element
sub setAtts {
    my ($node, %atts) = @_;
    $node->setAttribute($_, $atts{$_}) foreach keys %atts;
    return $node;
}

sub initXml {
    my ($default_zoom_level_name, $source_name, 
        $landmark_start, $landmark_end, $landmark_name,
        $tilewidth_pixels, $source) = @_;
    my $doc = new XML::DOM::Document();
    $doc->setXMLDecl($doc->createXMLDecl("1.0"));
    my $root = $doc->appendChild($doc->createElement("settings"));
    $root->appendChild($doc->createElement("defaults"))
        ->setAttribute("zoomlevelname", $default_zoom_level_name);
    setAtts($root->appendChild($doc->createElement("landmark")), 
            "name" => $source_name, "start" => $landmark_start,
            "end" => $landmark_end, "id" => $landmark_name);
    $root->appendChild($doc->createElement("tile"))
        ->setAttribute("width", $tilewidth_pixels);
    $root->appendChild($doc->createElement("tracks"));

    $root->appendChild($doc->createElement("classicurl"))
        ->setAttribute("url", "http://128.32.184.78/cgi-bin/gbrowse/${source}/");
    return $doc;
}

sub area {
    # writes out the area html 
    # since using this I am less happy with fact that all changes
    # (even javascript) then have to be pre rendered including mouseovers etc
    # a better way would be upload the area/coordinate data and then
    # update the area element with the parameters
    my ($x1,$y1,$x2,$y2,$feat)=@_;
    my $str="<area shape=rect coords=\"$x1,$y1,$x2,$y2\" href=\"javascript:MenuComponent_showDescription('<b>Feature</b>','<b>Name:</b>&nbsp;" . $feat->display_name . "<br><b>ID:</b>&nbsp;" . $feat->primary_id . "<br><b>Type:</b>&nbsp;" . $feat->primary_tag . "<br><b>Source:</b>&nbsp;" . $feat->source_tag . "<br>";
    foreach my $key ( $feat->get_all_tags() ) {
        $str .= "<b>$key</b>&nbsp;"
                . join(", ", $feat->get_tag_values($key)) . "<br>";
    }
    return $str . "')\">\n";
}

sub writeHTML {
    my ($xhtmlfile,
        $tile_num,
        $tilewidth_pixels,
        $image_height,
        $track_num,
        $tileURL,
        $small_tile_glyphs) = @_;

    # have to check that all the coords are in the rectangles
    my $lower_limit = $tile_num * $tilewidth_pixels;
    my $upper_limit = ($tile_num + 1) * $tilewidth_pixels;

    # make the image map per tile, including all the html that will be
    # imported into the div element big problem I can see here is how
    # to not make storing the features so redundant
    open (HTMLTILE, ">${xhtmlfile}")
        or die "ERROR: could not open ${xhtmlfile}!\n";

    if ($small_tile_glyphs) {
        print HTMLTILE "<img src=\"$tileURL\" ismap usemap=\"#tilemap_${track_num}_${tile_num}\" border=0>\n";
        print HTMLTILE "<map name=\"tilemap_${track_num}_${tile_num}\">\n";
        foreach my $box (@{$small_tile_glyphs}) {
            next unless $box->[0]->can('primary_tag');
            my ($x1, $y1, $x2, $y2) = @{$box}[1..4];

            # adjust coordinates to the correct tile
            $x1=$x1-$lower_limit;
            $x2=$x2-$lower_limit;   

            # tidy up coord edges
            $x2=$tilewidth_pixels if ( $x2 > $tilewidth_pixels );
            $x1=0 if ( $x1 < 0 );

            print HTMLTILE area($x1,$y1,$x2,$y2,$box->[0]);
        }
        print HTMLTILE "</map>\n";
    } else {
        print HTMLTILE "<img src=\"$tileURL\" border=0>";
    }
    close HTMLTILE or die "couldn't close HTMLTILE: $!\n";
}

sub setupPalette {
    my ($panel) = @_;
    my $gd = $panel->{gd};
    my %translation_table;
    foreach my $name ('white','black', $panel->color_names) {
        my @rgb = $panel->color_name_to_rgb($name);
        my $idx = $gd->colorAllocate(@rgb);
        $translation_table{$name} = $idx;
    }
    $panel->{translations} = \%translation_table;
}

# method to render a range of tiles
# NB tiles used 0-based indexing
sub renderTileRange {
    my ($first_tile,
        $last_tile,
        $tilewidth_pixels,
        $rendering_tilewidth,
        $tile_prefix,
        $is_global,
        $big_panel,
        $big_track,
        $image_height,
        $panel_args,
        $track_settings,
        $html_current_outdir,
        $tile_callback) = @_;

    # these should really divide evenly, and of course no one will MISUSE
    # the script, right? !!!

    # small tiles per large tile
    my $small_per_large = int ($rendering_tilewidth / $tilewidth_pixels);
    if ($small_per_large * $tilewidth_pixels != $rendering_tilewidth) {
        croak "Error: -renderWidth needs to be an integer multiple of -tileWidth";
    }

    my $first_large_tile = floor($first_tile / $small_per_large);
    my $last_large_tile = ceiling($last_tile / $small_per_large);

    # @per_tile_glyphs is a list with one element per rendering tile,
    # each of which is a list of the glyphs that overlap that tile.
    my @per_tile_glyphs;
    if (!$is_global) {
        foreach my $glyph ($big_track->parts) {
            my @box = $glyph->box;
            my @rtile_indices =
                floor($box[0] / $rendering_tilewidth)
                ..ceiling($box[2] / $rendering_tilewidth);

            foreach my $rtile_index (@rtile_indices) {
                push @{$per_tile_glyphs[$rtile_index]}, $glyph;
            }
        }
    }

#    $Data::Dumper::Maxdepth = 3;
#    print "per tile glyphs " . Dumper(@per_tile_glyphs[0..30]) . "\n";

    my $blankTile;
    my $linkCount = 0;
    my (%tileHash, %tileLinkCount);

    local *TILE;
    for (my $x = $first_large_tile; $x <= $last_large_tile; $x++) {
        my $large_tile_gd;
        my $pixel_offset = (0 == $x) ? 0 : $global_padding;

        if ($linkCount > MAX_LINKS) {
            undef $blankTile;
            $linkCount = 0;
        }

        # we want to skip rendering whole tile if it's blank, but only if
        # there's a blank tile to which to hardlink that's already rendered
        if (defined($per_tile_glyphs[$x]) || (!defined($blankTile))) {

            # rendering tile bounds in pixel coordinates
            my $rtile_left = ($x * $rendering_tilewidth) 
		- $pixel_offset;
            my $rtile_right = (($x + 1) * $rendering_tilewidth)
		+ $global_padding - 1;

            # rendering tile bounds in bp coordinates
            my $first_base = int($rtile_left / $big_panel->scale) + $big_panel->start;
            my $last_base = int(($rtile_right + 1) / $big_panel->scale) + $big_panel->start - 1;

            if (($big_panel->start == $first_base)
                && ($last_base > $big_panel->end)) {
                $big_panel->{gd} = undef;
                $large_tile_gd = $big_panel->gd();
            } else {
                # set up the per-rendering-tile panel, with the right
                # bp coordinates and pixel width
                my %tpanel_args = %$panel_args;
                $tpanel_args{-start} = $first_base;
                $tpanel_args{-end} = $last_base;
                $tpanel_args{-stop} = $last_base;
                $tpanel_args{-width} = $rtile_right - $rtile_left + 1;
                my $tile_panel = Bio::Graphics::Panel->new(%tpanel_args);
                my $scale_diff = $tile_panel->scale - $big_panel->scale;
                if (abs($scale_diff) > 1e-11) {
                    printf "scale difference: %e\n", $scale_diff;
                    print "big panel scale: " . $big_panel->scale . " big panel start: " . $big_panel->start . " big panel end: " . $big_panel->end . " big panel width: " . $big_panel->width . " small panel scale: " . $tile_panel->scale . " pixel_offset: $pixel_offset first_base: $first_base last_base: $last_base rtile_left: $rtile_left rtile_right: $rtile_right small panel width: " . $tile_panel->width . "\n";
                }

                if ($is_global) {
                    # for global features we can just render everything
                    # using the per-tile panel
                    # this arithmetic has been double checked
                    my @segments = 
                        $db->segment(-name => $landmark_name,
                                     -start => $first_base - $big_panel->start + 1,
                                     -end => $last_base - $big_panel->start + 1);
                    my $small_segment = $segments[0];
                    my $small_track;
                    if ($small_segment) {
                        $small_track = $tile_panel->add_track($small_segment,
                                                              @$track_settings);
                    } else {
                        $small_track = $tile_panel->add_track(@$track_settings);
                    }                        
                    if ($tile_panel->height < $big_panel->height) {
                        $tile_panel->pad_bottom($tile_panel->pad_bottom
                                                + ($big_panel->height
                                                   - $tile_panel->height));
                        $tile_panel->extend_grid(1);
                    }
                    $large_tile_gd = $tile_panel->gd();
                } else {
                    # add generic track to the tile panel, so that the
                    # gridlines have the right height
                    $tile_panel->add_track(-glyph => 'generic', 
                                           @$track_settings,
                                           -height => $image_height);
                    $large_tile_gd = $tile_panel->gd();
                    #print "got tile panel gd " . tv_interval($start_time) . "\n";
                    
                    if (defined $per_tile_glyphs[$x]) {
                        # some glyphs call set_pen on the big_panel;
                        # we want that to go to the right GD object
                        $big_panel->{gd} = $large_tile_gd;
                    
                        #move rendering onto the tile
                        $big_panel->pad_left(-$rtile_left);

                        # draw the glyphs for the current rendering tile
                        foreach my $glyph (@{$per_tile_glyphs[$x]}) {
                            # some positions are calculated
                            # using the panel's pad_left, and sometimes
                            # they're calculated using the x-coordinate
                            # passed into the draw method.  We want them
                            # both to be -$rtile_left.
                            $glyph->draw($large_tile_gd, -$rtile_left, 0);
                        }
                    }
                }
                $tile_panel->finished;
                $tile_panel = undef;
            }
        }

        # now to break up the large tile into small tiles and write them to PNG on disk...

        my @small_tile_boxes;
        foreach my $glyph (@{$per_tile_glyphs[$x]}) {
            my $box = [$glyph->feature, $glyph->box];
            my $first_small = floor($box->[1] / $tilewidth_pixels);
            my $last_small = floor($box->[3] / $tilewidth_pixels);
            my $small_begin = $x * $small_per_large;
            $first_small = $small_begin
                if $first_small < $small_begin;
            $last_small = ($small_begin + $small_per_large) - 1
                if $last_small > ($small_begin + $small_per_large) - 1;

            $first_small -= $small_begin;
            $last_small -= $small_begin;
            my @tile_indices = $first_small .. $last_small;

            foreach my $tile_index (@tile_indices) {
                push @{$small_tile_boxes[$tile_index]}, $box;
            }
        }

      SMALLTILE:
        for (my $y = 0; $y < $small_per_large; $y++) {
            my $small_tile_num = $x * $small_per_large + $y;
            if ( ($small_tile_num >= $first_tile)
                 && ($small_tile_num <= $last_tile) ) { # do we print it?

                my $outfile = "${tile_prefix}${small_tile_num}.png";
                my $tileURL = $html_current_outdir."tile".${small_tile_num}.".png";
                &$tile_callback($tile_prefix, $small_tile_num,
                                $tileURL, $small_tile_boxes[$y]);

                if (!$is_global && !defined($small_tile_boxes[$y])) {
                    if (defined($blankTile)) {
                        link $blankTile, $outfile
                            || die "could not link blank tile: $!\n";
                        $linkCount++;
                        next SMALLTILE;
                    } else {
                        $blankTile = $outfile;
                    }
                }

                my $small_tile_gd = GD::Image->new($tilewidth_pixels,
                                                   $image_height,
                                                   0);
                
                # can copy beyond panel width because of pad_right
                $small_tile_gd->copy($large_tile_gd,
                                     0, 0,
                                     $y * $tilewidth_pixels + $pixel_offset, 0,
                                     $tilewidth_pixels, $image_height);

                my $pngData = $small_tile_gd->png(4);
                if (!$is_global) {
                    # many tiles are identical (especially at high zoom)
                    # so we're not generating the tile if we've seen
                    # one with the same md5 already
                    # TODO: consider collisions in more depth (sha1?)
                    my $pngMD5 = md5($pngData);

                    if ($tileHash{$pngMD5}) {
                        if ($tileLinkCount{$pngMD5} > MAX_LINKS) {
                            $tileLinkCount{$pngMD5} = 0;
                            undef $tileHash{$pngMD5};
                        } else {
                            link $tileHash{$pngMD5}, $outfile;
                            $tileLinkCount{$pngMD5} += 1;
                            next SMALLTILE;
                        }
                    } else {
                        $tileHash{$pngMD5} = $outfile;
                        $tileLinkCount{$pngMD5} = 1;
                    }
                } else {
                    $small_tile_boxes[$y] = undef;
                }

                open (TILE, ">${outfile}")
                    or die "ERROR: could not open ${outfile}!\n";
                print TILE $pngData
                    or die "ERROR: could not write to ${outfile}!\n";
                warn "done printing ${outfile}\n" if $verbose >= 2;
            }
        }
    }
}

# --- HELPER FUNCTIONS ----

sub ceiling {
    my $i = shift;
    my $i_int = int($i);  # remember that 'int' truncates toward 0

    return $i_int + 1 if $i_int != $i and $i > 0;
    return $i_int;
}

sub floor {
    my $i = shift;
    my $i_int = int($i);  # remember that 'int' truncates toward 0
    
    return $i_int if $i >= 0 or $i_int == $i;
    return $i_int - 1;
}

sub print_usage {
    print <<ENDUSAGE;
USAGE
  generate-tiles.pl -l <landmark> [-c <config dir>] [-o <output dir>]
                    [-h <HTML path>] [-s <source>] [-m <mode>]
                    [-v <verbose>] [-r <selection>]
                    [-t <track list>]
                    [-d <density plot threshold>] [-p <label threshold>]
                    [--exit-early] [--print-tile-nums] [--no-xml]
                    [--render-gridlines]
where the options are:
  -l <landmark>
        name of landmark you want to render
  -c <config dir>
        directory containing browser and track info in the '.conf' file
        (default is '${default_confdir}')
  -o <output directory>
        directory to which '${xmlfile}' and the 'tiles' directory will be
        written to (default is '${default_outdir}')
  -s <source>
        source of configuration info in <config dir> (if there is more than
        one '.conf' file)
  -m <mode>
        specifies what you want this script to do:
          0 = fill database with GD primitives, render tiles, generate XML
              file (default)
          1 = fill database with GD primitives and generate XML file only
          2 = render tiles and generate XML file only ('gdtile' MySQL database
              must be filled already)
          3 = do nothing except generate XML file and dump info
  -v <verbose>
        sets whether to run in verbose mode (that is, output activities of the
        program's internals to standard error):
          0 = verbose off (default)
          1 = verbose on (regular)
          2 = verbose on (extreem - prints trace of every instance of
              recording or replaying database primitives and of every tile
              that is rendered - WARNING, VERY VERBOSE!)
  -t <track list>
        Specify the tracks to render (e.g. -t 1,2,3,4)
        default: render all tracks
  -r <selection>
        Use this to render only a subset of all possible tiles, tracks and
        zoom levels (default is render ALL tiles); note that CURRENTLY, the
        RANGE part of this option DOES NOT apply to loading the database with
        primitives or generating the XML file - i.e you can select which
        tracks and zoom levels to load into database or write to XML file with
        this, but NOT which tile ranges, since the range feature works for
        RENDERING only.

        <selection> is a comma-delimited concatenation (no whitespace) of any
        number of strings of the form:
          t<track number>z<zoom level number>r<tile number range>
        where <tile number range> is in the form:
          <start>-<end>
        and <track number>, <zoom level number>, and the full range of tiles
        for each track and zoom level can be obtained by running this script
        with the --print-tile-nums option (ALSO: please specify only ONE range
        per track and zoom level combination!)

        EXAMPLE: t1z5r100-500,t2z5r100-500 (print tiles 100 through 500,
                                            inclusive, for tracks 1 and 2,
                                            zoom level 5)
  -d <number of features>
        average number of features per tile above which we switch to a
        density histogram
        default: 200
  -p <number of features>
        average number of features per tile above which we won't print labels
        default: 50
  --exit-early
        a debug option; when enabled, the script exits after loading and
        outputting database info, but before doing anything else
  --print-tile-nums
        print how many tiles will be in each track at each zoom level (useful
        for getting tile ranges for '-r' option)
  --no-xml
        do not generate the XML file in any of the modes
  --render-gridlines
        render gridlines (default is do not render gridlines, since it
        increases the rendering time)

Use global paths everywhere for the least surprises.
ENDUSAGE
    
    exit 0;
}
