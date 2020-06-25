// Processes used for alignment of reads against gene databases

params.cag_batchsize = 100000

// Default options
params.distance_threshold = 0.5
params.distance_metric = "cosine"
params.linkage_type = "average"
params.famli_batchsize = 10000000

include makeInitialCAGs from "./make_cags" params(
    distance_threshold: params.distance_threshold / 2,
    distance_metric: params.distance_metric,
    linkage_type: params.linkage_type
)
include refineCAGs as refineCAGs_round1 from "./make_cags" params(
    distance_threshold: params.distance_threshold / 2,
    distance_metric: params.distance_metric,
    linkage_type: params.linkage_type
)
include refineCAGs as refineCAGs_round2 from "./make_cags" params(
    distance_threshold: params.distance_threshold / 2,
    distance_metric: params.distance_metric,
    linkage_type: params.linkage_type
)
include refineCAGs as refineCAGs_round3 from "./make_cags" params(
    distance_threshold: params.distance_threshold / 2,
    distance_metric: params.distance_metric,
    linkage_type: params.linkage_type
)
include refineCAGs as refineCAGs_round4 from "./make_cags" params(
    distance_threshold: params.distance_threshold / 2,
    distance_metric: params.distance_metric,
    linkage_type: params.linkage_type
)
include refineCAGs as refineCAGs_round5 from "./make_cags" params(
    distance_threshold: params.distance_threshold / 2,
    distance_metric: params.distance_metric,
    linkage_type: params.linkage_type
)
include refineCAGs as refineCAGs_final from "./make_cags" params(
    distance_threshold: params.distance_threshold,
    distance_metric: params.distance_metric,
    linkage_type: params.linkage_type
)

workflow alignment_wf {
    take:
        gene_fasta
        reads_ch
        output_prefix

    main:

    // Make a DIAMOND indexed database from those gene sequences
    diamondDB(
        gene_fasta
    )

    // Align all specimens against the DIAMOND database
    diamond(
        reads_ch,
        diamondDB.out
    )

    // Filter to the most likely single alignment per query
    famli(
        diamond.out
    )

    // Make a single table with the abundance of every gene across every sample
    assembleAbundances(
        famli.out.toSortedList(),
        params.cag_batchsize,
        output_prefix
    )

    // Group shards of genes into Co-Abundant Gene Groups (CAGs)
    makeInitialCAGs(
        assembleAbundances.out[0],
        assembleAbundances.out[1].flatten()
    )

    // Perform multiple rounds of combining shards to make ever-larger CAGs
    refineCAGs_round1(
        assembleAbundances.out[0],
        makeInitialCAGs.out.toSortedList().flatten().collate(2)
    )
    refineCAGs_round2(
        assembleAbundances.out[0],
        refineCAGs_round1.out.toSortedList().flatten().collate(2)
    )
    refineCAGs_round3(
        assembleAbundances.out[0],
        refineCAGs_round2.out.toSortedList().flatten().collate(2)
    )
    refineCAGs_round4(
        assembleAbundances.out[0],
        refineCAGs_round3.out.toSortedList().flatten().collate(2)
    )
    refineCAGs_round5(
        assembleAbundances.out[0],
        refineCAGs_round4.out.toSortedList().flatten().collate(2)
    )

    // Combine the shards and make a new set of CAGs
    refineCAGs_final(
        assembleAbundances.out[0],
        refineCAGs_round5.out.collect()
    )

    // Calculate the relative abundance of each CAG in these samples
    calcCAGabund(
        assembleAbundances.out[0],
        refineCAGs_final.out
    )

    emit:
        cag_csv = refineCAGs_final.out
        gene_abund_feather = assembleAbundances.out[0]
        cag_abund_feather = calcCAGabund.out
        famli_json_list = famli.out.toSortedList()
        specimen_gene_count_csv = assembleAbundances.out[2]
        specimen_reads_aligned_csv = assembleAbundances.out[5]
        detailed_hdf = assembleAbundances.out[3]
        gene_length_csv = assembleAbundances.out[4]
}

// Align each sample against the reference database of genes using DIAMOND
process diamondDB {
    tag "Make a DIAMOND database"
    container "quay.io/fhcrc-microbiome/famli@sha256:25c34c73964f06653234dd7804c3cf5d9cf520bc063723e856dae8b16ba74b0c"
    label 'mem_veryhigh'
    errorStrategy 'retry'
    publishDir "${params.output_folder}/ref/", mode: "copy"
    
    input:
    file fasta

    output:
    file "genes.dmnd"

    """
    set -e
    diamond \
      makedb \
      --in ${fasta} \
      --db genes.dmnd \
      --threads ${task.cpus}
    """

}


// Align each sample against the reference database of genes using DIAMOND
process diamond {
    tag "Align to the gene catalog"
    container "quay.io/fhcrc-microbiome/famli@sha256:25c34c73964f06653234dd7804c3cf5d9cf520bc063723e856dae8b16ba74b0c"
    label 'mem_veryhigh'
    errorStrategy 'retry'
    
    input:
    tuple val(sample_name), file(R1), file(R2)
    file refdb
    
    output:
    tuple sample_name, file("${sample_name}.aln.gz")

    """
    set -e

    for fp in ${R1} ${R2}; do
        cat \$fp | \
        gunzip -c | \
        awk "{if(NR % 4 == 1){print \\"@\$fp\\" NR }else{if(NR % 4 == 3){print \\"+\\"}else{print}}}" | \
        gzip -c \
        > query.fastq.gz

        diamond \
        blastx \
        --query query.fastq.gz \
        --out \$fp.aln.gz \
        --threads ${task.cpus} \
        --db ${refdb} \
        --outfmt 6 qseqid sseqid pident length mismatch gapopen qstart qend sstart send evalue bitscore qlen slen \
        --min-score ${params.dmnd_min_score} \
        --query-cover ${params.dmnd_min_coverage} \
        --id ${params.dmnd_min_identity} \
        --top ${params.dmnd_top_pct} \
        --block-size ${task.memory.toMega() / (1024 * 6 * task.attempt)} \
        --query-gencode ${params.gencode} \
        --compress 1 \
        --unal 0
    done

    cat *aln.gz > ${sample_name}.aln.gz
    """

}


// Filter the alignments with the FAMLI algorithm
process famli {
    tag "Deduplicate multi-mapping reads"
    container "quay.io/fhcrc-microbiome/famli:v1.5"
    label 'mem_veryhigh'
    publishDir "${params.output_folder}/abund/details/", mode: "copy"
    errorStrategy 'retry'
    
    input:
    tuple sample_name, file(input_aln)
    
    output:
    path "${sample_name}.json.gz"

    """
    set -e
    famli \
      filter \
      --input ${input_aln} \
      --output ${sample_name}.json \
      --threads ${task.cpus} \
      --batchsize ${params.famli_batchsize} \
      --sd-mean-cutoff ${params.sd_mean_cutoff}
    gzip ${sample_name}.json
    """

}


// Make a single feather file with the abundance of every gene across every sample
process assembleAbundances {
    tag "Make gene ~ sample abundance matrix"
    container "quay.io/fhcrc-microbiome/experiment-collection@sha256:fae756a380a3d3335241b68251942a8ed0bf1ae31a33a882a430085b492e44fe"
    label "mem_veryhigh"
    errorStrategy 'retry'

    input:
    file sample_jsons
    val cag_batchsize
    val output_prefix

    output:
    file "gene.abund.feather"
    file "gene_list.*.csv.gz"
    file "specimen_gene_count.csv.gz"
    file "${output_prefix}.details.hdf5"
    path "gene_length.csv.gz"
    path "specimen_reads_aligned.csv.gz"


    """
#!/usr/bin/env python3

import logging
import numpy as np
import os
import pandas as pd
import gzip
import json
import pickle
pickle.HIGHEST_PROTOCOL = 4

# Set up logging
logFormatter = logging.Formatter(
    '%(asctime)s %(levelname)-8s [assembleAbundances] %(message)s'
)
rootLogger = logging.getLogger()
rootLogger.setLevel(logging.INFO)

# Write logs to STDOUT
consoleHandler = logging.StreamHandler()
consoleHandler.setFormatter(logFormatter)
rootLogger.addHandler(consoleHandler)

def read_json(fp):
    return pd.DataFrame(
        json.load(
            gzip.open(fp, "rt")
        )
    )

# Parse the file list
sample_jsons = "${sample_jsons}".split(" ")
logging.info("Getting ready to read in data for %d sample" % len(sample_jsons))

# All of the abundances will go into a single dict
all_abund = dict()
# Also keep track of the complete set of gene names observed in these samples
all_gene_names = set([])

# All abundance tables will be written out to HDF5
store = pd.HDFStore("${output_prefix}.details.hdf5", "w")

# Keep track of the length of each gene
gene_length_dict = dict()

# Keep track of the number of reads aligned per sample
specimen_reads_aligned = dict()

# Iterate over the list of files
for fp in sample_jsons:
    # Get the sample name from the file name
    # This is only possible because we control the file naming scheme in the `famli` process
    assert fp.endswith(".json.gz")
    sample_name = fp[:-len(".json.gz")]

    logging.info("Reading in %s from %s" % (sample_name, fp))
    df = read_json(fp)

    logging.info("Saving to HDF5")
    df.to_hdf(store, "/abund/gene/long/%s" % sample_name)
    
    logging.info("Saving depth in memory")
    all_abund[sample_name] = df.set_index("id")["depth"].to_dict()

    # Add the gene names to the total list
    for gene_name in all_abund[sample_name]:
        all_gene_names.add(gene_name)

    # Add the gene lengths
    for _, r in df.iterrows():
        gene_length_dict[r["id"]] = r["length"]

    # Add in the number of reads aligned
    specimen_reads_aligned[sample_name] = df["nreads"].sum()

store.close()

# Serialize sample and gene names
sample_names = list(all_abund.keys())
all_gene_names = list(all_gene_names)

# Now make a DataFrame for all of this data
df = pd.DataFrame(
    np.zeros((len(all_gene_names), len(sample_names)), dtype=np.float32),
    columns=sample_names,
    index=all_gene_names
)

# Add all of the data to the DataFrame
for sample_name, sample_abund in all_abund.items():
    # Format as a Pandas Series
    sample_abund = pd.Series(
        sample_abund
    )

    # Divide by the sum to get the proportional abundance
    sample_abund = sample_abund / sample_abund.sum()

    # Add the values to the table
    df.values[
        :, sample_names.index(sample_name)
    ] = sample_abund.reindex(
        index=all_gene_names
    ).fillna(
        0
    ).apply(
        np.float32
    ).values

# Write out the number of genes detected per sample
pd.DataFrame(
    dict(
        [
            (
                "n_genes_aligned", 
                (df > 0).sum()
            )
        ]
    )
).reset_index(
).rename(
    columns = dict(
        [
            ("index", "specimen")
        ]
    )
).to_csv(
    "specimen_gene_count.csv.gz",
    index=None,
    compression = "gzip"
)

# Write out the number of reads aligned per sample
pd.DataFrame(
    dict(
        [
            (
                "n_reads_aligned", 
                specimen_reads_aligned
            )
        ]
    )
).reset_index(
).rename(
    columns = dict(
        [
            ("index", "specimen")
        ]
    )
).to_csv(
    "specimen_reads_aligned.csv.gz",
    index=None,
    compression = "gzip"
)

# Write out the CSV table with the length of each gene
pd.DataFrame([
    dict([("gene", gene), ("length", length)])
    for gene, length in gene_length_dict.items()
]).to_csv(
    "gene_length.csv.gz",
    index = None,
    compression = "gzip"
)

# Write out the abundances to a feather file
logging.info("Writing to disk")
df.reset_index(inplace=True)
df.to_feather("gene.abund.feather")

# Write out the gene names in batches of ${params.cag_batchsize}
for ix, gene_list in enumerate([
    all_gene_names[ix: (ix + ${cag_batchsize})]
    for ix in range(0, len(all_gene_names), ${cag_batchsize})
]):
    print("Writing out %d genes in batch %d" % (len(gene_list), ix))
    with gzip.open("gene_list.%d.csv.gz" % ix, "wt") as handle:
        handle.write("\\n".join(gene_list))

logging.info("Done")

    """

}


// Summarize the abundance of every CAG across each sample
process calcCAGabund {
    tag "Make CAG ~ sample abundance matrix"
    container "quay.io/fhcrc-microbiome/experiment-collection@sha256:fae756a380a3d3335241b68251942a8ed0bf1ae31a33a882a430085b492e44fe"
    label "mem_veryhigh"
    errorStrategy 'retry'
    publishDir "${params.output_folder}/abund/", mode: "copy"

    input:
    path gene_feather
    path cag_csv_gz

    output:
    file "CAG.abund.feather"

    """
#!/usr/bin/env python3

import feather
import pandas as pd
import logging

# Set up logging
logFormatter = logging.Formatter(
    '%(asctime)s %(levelname)-8s [calculateCAGabundance] %(message)s'
)
rootLogger = logging.getLogger()
rootLogger.setLevel(logging.INFO)

# Write logs to STDOUT
consoleHandler = logging.StreamHandler()
consoleHandler.setFormatter(logFormatter)
rootLogger.addHandler(consoleHandler)

# Read in the table of CAGs
cags_df = pd.read_csv(
    "${cag_csv_gz}",
    compression="gzip"
)

# Read in the table of gene abundances
abund_df = pd.read_feather(
    "${gene_feather}"
).set_index(
    "index"
)

# Annotate each gene with the CAG it was assigned to
abund_df["CAG"] = cags_df.set_index("gene")["CAG"]

# Make sure that every gene was assigned to a CAG
assert abund_df["CAG"].isnull().sum() == 0

# Now sum up the gene relative abundance by CAGs
# and write out to a feather file
abund_df.groupby(
    "CAG"
).sum(
).reset_index(
).to_feather(
    "CAG.abund.feather"
)

logging.info("Done")
    """
}