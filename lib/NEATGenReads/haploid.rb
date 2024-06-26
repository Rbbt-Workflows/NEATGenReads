module NEATGenReads
  def self.haploid_chr(chr, pos, alternatives=nil)
    return chr if chr =~ /^copy-\d+_/
    chr = chr.sub(/^chr/,'')
    num = Misc.digest(chr + ":" << pos.to_s)[-1].hex
    alternatives=%w(copy-1_chr copy-2_chr).collect{|p| p + chr } if alternatives.nil?
    alternatives[num % alternatives.length]
  end

  def self.haploid_mutation(mutation, alternatives=%w(copy-1_chr copy-2_chr))
    chr, pos, alt = mutation.split(":")
    chr = haploid_chr(chr, pos, alternatives)
    [chr, pos, alt] * ":"
  end

  def self.mutation_reference(mutations, reference_file)
    sizes = Samtools.contig_sizes(reference_file)

    contigs = sizes.keys
    copies = {}
    contigs.each do |contig|
      if m = contig.match(/^(copy-\d+)_(?:chr)?(.*)/)
        copy, orig = m.captures
      else
        orig = contig
      end
      next if orig == contig
      copies[orig] ||= []
      copies[orig] << contig
    end

    mutation_ranges = mutations.collect do |m| 
      chr, pos, alt = m.split(":")
      chr = chr.sub(/^chr/,'')

      chr = haploid_chr(chr, pos, copies[chr]) if copies[chr]

      chr = "chr" + chr if sizes[chr].nil? && chr !~ /^(copy|chr)/
      chr = chr.sub(/^chr/,'') if sizes[chr].nil? && chr =~ /^chr/

      next if sizes[chr].nil?

      pos = pos.to_i
      if alt["-"]
        pos = pos - 1
        eend = pos + alt.length
      else
        eend = pos
      end


      next if eend > sizes[chr]

      chr + ":" + pos.to_s + "-" + eend.to_s
    end.compact

    reference = TSV.setup({}, :key_field => "Genomic Mutation", :fields => ["Reference"], :type => :single)

    TmpFile.with_file(mutation_ranges * "\n") do |ranges|
      pos_reference = TSV.setup({}, "Genomic Position~Reference#:type=:single")
      TSV.traverse CMD.cmd(:samtools, "faidx #{reference_file} -r #{ranges} 2> /dev/null | tr '\\n' '\\t' | tr '>' '\\n'", :pipe => true), :type => :array do |line|
        pos_info, ref = line.split("\t")
        next if ref.nil?
        chr, range = pos_info.split(":")
        pos = range.split("-").first
        pos_reference[[chr, pos]] = ref
      end

      mutations.each do |mutation|
        chr, pos, alt = mutation.split(":")

        chr = haploid_chr(chr, pos, copies[chr]) if copies[chr]
        chr = "chr" + chr if sizes[chr].nil? && chr !~ /^(copy|chr)/
        chr = chr.sub(/^chr/,'') if sizes[chr].nil? && chr =~ /^chr/

        next if sizes[chr].nil?

        mutation = [chr, pos, alt] * ":"

        pos = pos.to_i
        if alt["-"]
          pos = pos - 1
          eend = pos + alt.length
        else
          eend = pos
        end

        next if eend > sizes[chr]
        
        ref = pos_reference[[chr, pos.to_s]]
        raise mutation if ref.nil? || ref.empty?
        reference[mutation] = ref
      end
    end

    reference
  end

  def self.haploid_SV(values)
    type, chr, start, eend, target_chr, target_start, target_end = values

    chr = chr.to_s.sub(/^chr/, '')
    target_chr = target_chr.to_s.sub(/^chr/, '') if target_chr && ! target_chr.empty?
    target_chr = target_chr.to_s

    if !chr.include?('copy-') 
      chr_copies = %w(copy-1_chr copy-2_chr)
      num = Misc.digest([chr, start, eend, type] * ":")[-1].hex
      chr = chr_copies[num % chr_copies.length] + chr
    end

    target_chr = chr if target_chr == 'same' || target_chr == 'cis'

    if target_chr && ! target_chr.empty? && ! target_chr.include?('copy-')
      chr_copies = %w(copy-1_chr copy-2_chr)
      num = Misc.digest([chr, start, eend, target_chr, type] * ":")[-1].hex
      target_chr = chr_copies[num % chr_copies.length] + target_chr
    end

    [type, chr, start, eend, target_chr, target_start, target_end]
  end
end
