task read_header {
  File unalignedBam
  String bamName

  command {
    samtools view -H ${unalignedBam} | \
    perl -nae 'next unless /^\@RG/; s/\tPI:\t/\t/; s/\tPI:\s*\t/\t/; s/\tPI:\s*\z/\n/; s/\t/\\t/g; print' > "${bamName}_header.txt"
  }

  output {
    File header_file = "${bamName}_header.txt"
  }

  runtime {
    tool: "pcawg-bwa-mem-workflow-generic"
    strategy: "routed_file"
  }
}

task count_reads {
  File unalignedBam
  String bamName

  command {
    samtools view ${unalignedBam} | \
    wc -l > "${bamName}_read_count.txt"
  }

  output {
    File counts_file = "${bamName}_read_count.txt"
  }

  runtime {
    tool: "pcawg-bwa-mem-workflow-generic"
    strategy: "routed_file"
  }
}

task align {
  File unalignedBam
  File bamHeader
  File reference_gz
  File reference_gz_fai
  File reference_gz_amb
  File reference_gz_ann
  File reference_gz_bwt
  File reference_gz_pac
  File reference_gz_sa
  String bamName
  Int threads
  Int sortMemMb

  command {
    sh -c ' \
    bamtofastq exlcude=QCFAIL,SECONDARY,SUPPLEMENTARY T=${bamName + ".t"} S=${bamName + ".s"} O=${bamName + ".o"} O2=${bamName + ".o2"} collate=1 tryoq=1 filename=${unalignedBam} | \
    bwa mem -p -t ${threads} -T 0 -R "$(cat ${bamHeader})" ${reference_gz} - | \
    bamsort blockmb=${sortMemMb} inputformat=sam level=1 outputthreads=2 calmdnm=1 calmdnmrecompindetonly=1 calmdnmreference=${reference_gz} tmpfile=${bamName + ".sorttmp"} O=${bamName + "_aligned.bam"} \
    '
  }

  output {
    File bam_output = "${bamName}_aligned.bam"
  }

  runtime {
    tool: "pcawg-bwa-mem-workflow-align"
    strategy: "routed_file"
  }
}

task bam_stats_qc {
  File bamHeader
  File readCount
  File bam
  String bamName

  command {
    sh -c ' \
    bam_stats -i ${bam} -o ${bamName + ".bas"} \
    && \
    verify_read_groups.pl --header-file ${bamHeader} --bas-file ${bamName + ".bas"} --input-read-count-file ${readCount} \
    '
  }

  output {
    File bam_stats = "${bamName}.bas"
  }

  runtime {
    tool: "pcawg-bwa-mem-workflow-generic"
    strategy: "routed_file"
  }
}

task merge {
  Array[File]+ inputBams
  String outputFilePrefix
  Int threads

  command {
    bammarkduplicates \
    I=${sep=" I=" inputBams} \
    O=${outputFilePrefix + ".bam"} \
    M=${outputFilePrefix + ".metrics"} \
    tmpfile=${outputFilePrefix + ".biormdup"} \
    markthreads=${threads} \
    rewritebam=1 \
    rewritebamlevel=1 \
    index=1 \
    md5=1
  }

  output {
    File merged_bam = "${outputFilePrefix}.bam"
    File merged_bam_bai = "${outputFilePrefix}.bam.bai"
    File merged_bam_metrics = "${outputFilePrefix}.metrics"
  }

  runtime {
    tool: "pcawg-bwa-mem-workflow-merge"
    strategy: "routed_file"
  }
}

task extract_unaligned_reads {
  File inputBam
  File reference_gz
  File reference_gz_fai
  String outputFilePrefix
  Int sortMemMb
  Int f

  command {
    sh -c ' \
    samtools view -h -f ${f} ${inputBam} | \
    remove_both_ends_unmapped_reads.pl | \
    bamsort blockmb=${sortMemMb} inputformat=sam level=1 outputthreads=2 calmdnm=1 calmdnmrecompindetonly=1 calmdnmreference=${reference_gz} tmpfile=${outputFilePrefix + ".sorttmp"} O=${outputFilePrefix + "_unmappedReads_f" + f + ".bam"} \
    '
  }

  output {
    File unmapped_reads = "${outputFilePrefix}_unmappedReads_f${f}.bam"
  }

  runtime {
    tool: "pcawg-bwa-mem-workflow-extract"
    strategy: "routed_file"
  }
}

task extract_both_reads_unaligned {
  File inputBam
  String outputFilePrefix

  command {
    samtools view -h -b -f 12 ${inputBam} > "${outputFilePrefix}_unmappedReads_f12.bam"
  }

  output {
    File unmapped_reads = "${outputFilePrefix}_unmappedReads_f12.bam"
  }

  runtime {
    tool: "pcawg-bwa-mem-workflow-extract"
    strategy: "routed_file"
  }
}

workflow pcawg_bwa_mem_workflow {
  Array[File]+ unalignedBams
  File reference_gz
  File reference_gz_fai
  String inputBasename
  String outputFilePrefix
  Int sortMemMb = 8000
  Int threads = 8

  scatter(bam in unalignedBams) {
    call read_header {
      input: unalignedBam=bam, 
             bamName=inputBasename
    }

    call count_reads {
      input: unalignedBam=bam,
             bamName=inputBasename
    }

    call align {
      input: unalignedBam=bam,
             bamHeader=read_header.header_file,
             bamName=inputBasename,
             threads=threads,
             sortMemMb=sortMemMb,
             reference_gz=reference_gz,
             reference_gz_fai=reference_gz_fai
    }

    call bam_stats_qc {
      input: bam=align.bam_output,
             bamHeader=read_header.header_file,
             readCount=count_reads.counts_file,
             bamName=inputBasename
    }
  }

  call merge {
    input: inputBams=align.bam_output,
           threads=threads,
           outputFilePrefix=outputFilePrefix
  }

  call extract_unaligned_reads as get_unmapped {
    input: inputBam=merge.merged_bam,
           f=4,
           sortMemMb=sortMemMb,
           outputFilePrefix=outputFilePrefix,
           reference_gz=reference_gz,
           reference_gz_fai=reference_gz_fai
  }

  call extract_unaligned_reads as get_unmapped_mate {
    input: inputBam=merge.merged_bam,
           f=8,
           sortMemMb=sortMemMb,
           outputFilePrefix=outputFilePrefix,
           reference_gz=reference_gz,
           reference_gz_fai=reference_gz_fai
  }

  call extract_both_reads_unaligned {
    input: inputBam=merge.merged_bam, 
           outputFilePrefix=outputFilePrefix
  }

  call merge as merge_unmapped {
    input: inputBams=[get_unmapped.unmapped_reads, get_unmapped_mate.unmapped_reads, extract_both_reads_unaligned.unmapped_reads],
           threads=threads,
           outputFilePrefix=outputFilePrefix
  }
}
