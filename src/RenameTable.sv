module RenameTable
#(
    parameter NUM_LOOKUP=8,
    parameter NUM_ISSUE=4,
    parameter NUM_COMMIT=4,
    parameter NUM_WB=4,
    parameter NUM_REGS=32,
    parameter ID_SIZE=$clog2(NUM_REGS),
    parameter TAG_SIZE=7
)
(
    input wire clk,
    input wire rst,
    input wire IN_mispred,
    input wire IN_mispredFlush,

    input wire[ID_SIZE-1:0] IN_lookupIDs[NUM_LOOKUP-1:0],
    output reg OUT_lookupAvail[NUM_LOOKUP-1:0],
    output reg[TAG_SIZE-1:0] OUT_lookupSpecTag[NUM_LOOKUP-1:0],
    
    input wire IN_issueValid[NUM_ISSUE-1:0],
    input wire[ID_SIZE-1:0] IN_issueIDs[NUM_ISSUE-1:0],
    input wire[TAG_SIZE-1:0] IN_issueTags[NUM_ISSUE-1:0],
    input wire IN_issueAvail[NUM_ISSUE-1:0],
    
    input wire IN_commitValid[NUM_COMMIT-1:0],
    input wire[ID_SIZE-1:0] IN_commitIDs[NUM_COMMIT-1:0],
    input wire[TAG_SIZE-1:0] IN_commitTags[NUM_COMMIT-1:0],
    input wire IN_commitAvail[NUM_COMMIT-1:0],
    output reg[TAG_SIZE-1:0] OUT_commitPrevTags[NUM_COMMIT-1:0],

    input wire IN_wbValid[NUM_WB-1:0],
    input wire[TAG_SIZE-1:0] IN_wbTag[NUM_WB-1:0]
);

localparam NUM_TAGS = (1 << (TAG_SIZE - 1));

typedef struct packed
{
    bit[TAG_SIZE-1:0] comTag;
    bit[TAG_SIZE-1:0] specTag;
} RATEntry;

RATEntry rat[NUM_REGS-1:0] /*verilator public*/;
reg[NUM_TAGS-1:0] tagAvail;

always_comb begin
    for (integer i = 0; i < NUM_LOOKUP; i=i+1) begin
        OUT_lookupSpecTag[i] = rat[IN_lookupIDs[i]].specTag;
        OUT_lookupAvail[i] = tagAvail[OUT_lookupSpecTag[i][TAG_SIZE-2:0]] | OUT_lookupSpecTag[i][TAG_SIZE-1];
        
        // Results that are written back in the current cycle also need to be marked as available
        for (integer j = 0; j < NUM_WB; j=j+1) begin
            if (IN_wbValid[j] && IN_wbTag[j] == OUT_lookupSpecTag[i])
                OUT_lookupAvail[i] = 1;
        end
        // Later lookups are affected by previous ops, even in the same cycle
        for (integer j = 0; j < (i / 2); j=j+1) begin
            if (IN_issueValid[j] && IN_issueIDs[j] == IN_lookupIDs[i] && IN_issueIDs[j] != 0) begin
                OUT_lookupAvail[i] = IN_issueAvail[j];
                OUT_lookupSpecTag[i] = IN_issueTags[j];
            end
        end
    end
    
    for (integer i = 0; i < NUM_COMMIT; i=i+1) begin
        OUT_commitPrevTags[i] = rat[IN_commitIDs[i]].comTag;
    end
end

always_ff@(posedge clk) begin
    
    if (rst) begin
        // Registers initialized with 0
        for (integer i = 0; i < NUM_REGS; i=i+1) begin
            rat[i].comTag <= 7'h40;
            rat[i].specTag <= 7'h40;
        end
        tagAvail <= {NUM_TAGS{1'b1}};
    end
    else begin
        // Written back values are speculatively available
        for (integer i = 0; i < NUM_WB; i=i+1) begin
            if (IN_wbValid[i] && !IN_wbTag[i][TAG_SIZE-1]) begin
                tagAvail[IN_wbTag[i][TAG_SIZE-2:0]] <= 1;
            end
        end
        
        if (IN_mispred) begin
            for (integer i = 1; i < NUM_REGS; i=i+1) begin
                // Ideally we would set specTag to the last specTag that isn't post incoming branch.
                // We can't keep such a history for every register though. As such, we flush the pipeline
                // after a mispredict. After flush, all results are committed, and rename can continue again.
                rat[i].specTag <= rat[i].comTag;
            end
        end
        else begin
            for (integer i = 0; i < NUM_ISSUE; i=i+1) begin
                if (IN_issueValid[i] && IN_issueIDs[i] != 0) begin
                    rat[IN_issueIDs[i]].specTag <= IN_issueTags[i];
                    
                    if (!IN_issueTags[i][TAG_SIZE-1]) begin
                        tagAvail[IN_issueTags[i][TAG_SIZE-2:0]] <= 0;
                        assert(IN_issueAvail[i] == 0);
                    end
                end
            end
        end
        
        for (integer i = 0; i < NUM_COMMIT; i=i+1) begin
            if (IN_commitValid[i] && IN_commitIDs[i] != 0) begin
                if (IN_mispredFlush) begin
                    if (!IN_mispred) begin
                        rat[IN_commitIDs[i]].specTag <= IN_commitTags[i];
                    end
                end
                else begin
                    rat[IN_commitIDs[i]].comTag <= IN_commitTags[i];
                    if (IN_mispred)
                        rat[IN_commitIDs[i]].specTag <= IN_commitTags[i];
                end
            end
        end
    end
end

endmodule
