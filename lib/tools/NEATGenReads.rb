module NEATGenReads

  Rbbt.claim Rbbt.software.opt.NEATGenReads, :install do
    commands=<<~EOF
chmod +x ${OPT_DIR}/NEATGenReads/gen_reads.py; sed -i 's/env source/env python/' ${OPT_DIR}/NEATGenReads/gen_reads.py; [[ -f ${OPT_DIR}/bin/gen_reads.py ]] || ln -s ../NEATGenReads/genReads.py ${OPT_DIR}/bin/gen_reads.py
    EOF
    {:git => "https://github.com/zstephens/neat-genreads.git",
     :commands => commands}
  end

  CMD.tool "gen_reads.py", Rbbt.software.opt.NEATGenReads, "gen_reads.py --help"

  def self.simulate(reference, mutations_vcf, output, depth: 60, ploidy: 2, read_length: 125, error_rate: nil, gc_model: nil)

    cmd = "-c #{depth} -r '#{reference}' -E #{error_rate} -p #{ploidy} -M 0 -R #{read_length} --pe 300 30 -o '#{output}' -v '#{mutations_vcf}' --vcf --bam"

    cmd += " -E #{error_rate}" if error_rate
    
    cmd += " --gc-model #{gc_model}" if gc_model

    CMD.cmd_log("gen_reads.py", cmd)
  end
end
