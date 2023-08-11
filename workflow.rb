Misc.add_libdir if __FILE__ == $0

#require 'scout/sources/NEATGenReads'
require 'tools/NEATGenReads'
require 'NEATGenReads/haploid'
require 'NEATGenReads/minify'
require 'NEATGenReads/rename'

Workflow.require_workflow "Sequence"
Workflow.require_workflow "HTS"
require 'tools/samtools'

module NEATGenReads
  extend Workflow

  input :reference, :file, "Reference file", nil, :nofile => true
  input :organism, :string, "Organism code"
  input :build, :select, "Organism build", "hg38", :select_options => %w(hg19 b37 hg39 GRCh38 GRCh37)
  extension 'fa.gz'
  task :prepare_reference => :binary do |reference,organism,build|
    if reference
      build = File.basename(reference).sub(/\.gz$/,'').sub(/\.(fa)/,'')
    else
      build ||= Organism.organism_to_build(options[:organism])
      reference = HTS.helpers[:reference_file].call(build)
    end

    output = file(build)

    reference_path = Path.setup(File.dirname(reference))

    files = reference_path.glob_all("**/*")

    files_info = files.collect{|file| [file, file.sub(reference_path.find, '')] * "<=>" }

    Open.ln_s reference_path, output

    reference = output["#{build}.fa.gz"]

    chr_reference = file('chr_reference')
    Open.mkdir chr_reference

    chrs = []
    file = nil
    TSV.traverse reference, :type => :array, :bar => self.progress_bar("Dividing reference contigs") do |line|

      if m = line.match(/>([^\s]*)/)
        chr = m.captures[0]
        chrs << chr
        file.close if file
        file = Open.open(chr_reference[chr].reference, :mode => 'w')
        line = line.split(/\s/).first
      end

      file.puts line
    end
    file.close

    Open.ln_s reference, self.tmp_path
    nil
  end

  input :mutations, :array, "Mutations to match to reference", []
  input :reference, :file, "Reference file", nil, :nofile => true
  task :mutations_to_reference =>  :tsv do |mutations,reference|
    reference = reference.path if Step === reference
    reference = Samtools.prepare_FASTA(reference, file('reference'))
    mutation_reference_tsv = NEATGenReads.mutation_reference(mutations, reference).to_s
  end

  dep :prepare_reference
  dep :mutations_to_reference, :reference => :prepare_reference
  input :depth, :integer, "Sequencing depth to simulate", 60
  input :haploid_reference, :boolean, "Reference is haploid (each chromosome copy separate)"
  input :sample_name, :string, "Sample name", nil, :jobname => true
  input :no_errors, :boolean, "Don't simulate sequencing errors", false
  input :rename_reads, :boolean, "Rename reads to include position info", true
  input :restore_svs, :tsv, "SVs to consider when renaming reads", nil, :nofile => true
  input :error_rate, :float, "Error rate to rescale the error mode to have it as mean", -1
  input :read_length, :integer, "Read length to simulate", 126
  input :gc_model, :file, "GC empirical model"
  dep Sequence, :mutations_to_vcf, "Sequence#reference" => :mutations_to_reference, :not_overriden => true, :mutations => :skip, :organism => :skip, :positions => :skip
  task :NEAT_simulate_DNA => :array do |depth,haploid,sample_name,no_errors,rename_reads,svs,error_rate,read_length,gc_model|

    if haploid
      depth = (depth.to_f / 2).ceil
      ploidy = 2
    else
      ploidy = 2
    end

    mutations_vcf = file('mutations.vcf')
    Open.write(mutations_vcf) do |sin|
      vcf = step(:mutations_to_vcf)
      vcf.join
      TSV.traverse vcf, :type => :array do |line|
        l = if line =~ /^(?:##)/ 
            line
            elsif line =~ /^#CHR/
              line + "\t" + "FORMAT" + "\t" + "Sample"
            else
              line = "chr" + line unless line =~ /^chr/ || line =~ /^copy/
              parts = line.split("\t")[0..4]

              parts[4] = parts[4].split(",").first if parts[4]

              (parts + [".", "PASS", ".", "GT", (haploid ? "1|1" : (rand < 0.5 ? "0|1" : "1|0"))]) * "\t"
            end
        sin.puts l
      end
    end

    chr_reference = step(:prepare_reference).file('chr_reference')

    chr_output = file('chr_output')
    output = file('output')

    fq1 = output[sample_name] + "_read1.fq"
    fq2 = output[sample_name] + "_read2.fq"
    bam = output[sample_name] + ".bam"

    cpus = config(:cpus, :genReads, :NEAT, :gen_reads)
    chrs = chr_reference.glob("*").collect{|f| File.basename(f) }
    chrs.reject! do |chr| 
      chr.include?("HLA") ||
      chr.include?("decoy") ||
      chr.include?("random") ||
      chr.include?("alt") ||
      chr.include?("chrUn") ||
      chr.include?("EBV")
    end
    iif chrs
    TSV.traverse chrs, :type => :array, :cpus => cpus, :bar => self.progress_bar("Generating reads by chromosome") do |chr|
      Open.mkdir chr_output[chr]
      reference = chr_reference[chr].reference
      error_rate = 0 if no_errors
      NEATGenReads.simulate(reference, mutations_vcf, chr_output[chr][sample_name], depth: depth, ploidy: ploidy, read_length: read_length, error_rate: error_rate, gc_model: gc_model)
    end 
    
    # Merge VCF
    vcf_file = output[sample_name] + ".vcf"
    vcf = Open.open(vcf_file, :mode => "w")

    header = true
    chr_output.glob("*/*.vcf.gz").each do |file|
      TSV.traverse file, :type => :array do |line|
        next if not header and line =~ /^#/
        next if line =~ /^##reference/
        vcf.puts line
      end
      header = false
    end
    vcf.close

    if svs
      Open.write(file('tmp.vcf'), NEATGenReads.restore_VCF_positions(vcf, svs, self.progress_bar("Restoring VCF positions")))
      Open.mv file('tmp.vcf'), vcf_file
    end

    # Merge BAM
    bam_parts = chr_output.glob("*/*.bam")

    Misc.in_dir chr_output do
      relative_bam_parts = bam_parts.collect{|p| "'" + Misc.path_relative_to(chr_output, p) + "'" }
      CMD.cmd(:samtools, "merge -f '#{bam}' #{relative_bam_parts * " "}")
    end

    # Merge FASTQ
    Open.rm fq1
    CMD.cmd("zcat '#{chr_output}'/*/*_read1.fq.gz >> '#{fq1}'")
    
    Open.rm fq2
    CMD.cmd("zcat '#{chr_output}'/*/*_read2.fq.gz >> '#{fq2}'")

    # Rename reads
    if rename_reads
      tmp1 = file('tmp1.fq.gz')
      tmp2 = file('tmp2.fq.gz')
      NEATGenReads.rename_FASTQ_reads(bam, fq1, fq2, tmp1, tmp2, svs, self.progress_bar("Adding position info to reads"))
      Open.mv tmp1, fq1
      Open.mv tmp2, fq2
      Open.mv fq1, fq1 + '.gz'
      Open.mv fq2, fq2 + '.gz'
    else
      output.glob("*.fq").each do |file|
        CMD.cmd("gzip '#{file}'")
      end
    end


    CMD.cmd(:bgzip, output[sample_name] + ".vcf")

    # Cleanup parts
    FileUtils.rm_rf chr_output

    output.glob("*.fq.gz")
  end
end

#require 'NEATGenReads/tasks/basic.rb'

#require 'scout/knowledge_base/NEATGenReads'
#require 'scout/entity/NEATGenReads'
