import sys

tag_strings = open("src/tag_strings.h", "w")
tag_enum = open("src/tag_enum.h", "w")
tag_sizes = open("src/tag_sizes.h", "w")

tag_py = open("python/gumbo/gumboc_tags.py", "w")
tag_py.write('TagNames = [\n')

tagfile = open(sys.argv[1])

for tag in tagfile:
    tag = tag.strip()
    tag_upper = tag.upper().replace('-', '_')
    tag_strings.write('"%s",\n' % tag)
    tag_enum.write('GUMBO_TAG_%s,\n' % tag_upper)
    tag_sizes.write('%d, ' % len(tag))
    tag_py.write('\t"%s",\n' % tag_upper)

tagfile.close()

tag_strings.close()
tag_enum.close()
tag_sizes.close()

tag_py.write(']\n')
tag_py.close()
