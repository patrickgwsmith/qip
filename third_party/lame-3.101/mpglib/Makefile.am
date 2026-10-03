## $Id$

include $(top_srcdir)/Makefile.am.global

INCLUDES = @INCLUDES@ -I$(top_srcdir)/libmp3lame -I$(top_builddir)
# Avoid -I. which obscures libmpg123's mpg123.h
DEFAULT_INCLUDES =

EXTRA_DIST = \
	AUTHORS \
	README

DEFS = @DEFS@ @CONFIG_DEFS@

noinst_HEADERS = mpglib.h

#$(OBJECTS): libtool
#libtool: $(LIBTOOL_DEPS)
#	$(SHELL) $(top_builddir)/config.status --recheck
