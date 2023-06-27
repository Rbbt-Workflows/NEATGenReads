module NEATGenreads

  Rbbt.claim Rbbt.software.opt.NEATGenReads, :install do
    commands=<<~EOF
chmod +x ${OPT_DIR}/NEATGenReads/gen_reads.py; sed -i 's/env source/env python/' ${OPT_DIR}/NEATGenReads/gen_reads.py; [[ -f ${OPT_DIR}/bin/gen_reads.py ]] || ln -s ../NEATGenReads/genReads.py ${OPT_DIR}/bin/gen_reads.py
    EOF
    {:git => "https://github.com/zstephens/neat-genreads.git",
     :commands => commands}
  end

  CMD.tool "gen_reads.py", Rbbt.software.opt.NEATGenReads, "gen_reads.py --help"
end
