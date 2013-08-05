from redshift._state cimport *
from redshift.beam cimport TaggerBeam, TagState, fill_hist, get_p, get_pp
#, TagKernel
from features.extractor cimport Extractor
from learn.perceptron cimport Perceptron
import index.hashes
cimport index.hashes
from redshift.io_parse cimport Sentences, Sentence
from libc.stdlib cimport malloc, calloc, free
from libc.string cimport memcpy, memset
from libc.stdint cimport uint64_t, int64_t
from libcpp.vector cimport vector 

from os.path import join as pjoin
import os
import os.path
from os.path import join as pjoin
import random
import shutil

DEBUG = False

cdef class BeamTagger:
    cdef Extractor features
    cdef Perceptron guide
    cdef object model_dir
    cdef size_t beam_width
    cdef int feat_thresh
    cdef size_t max_feats
    cdef size_t nr_tag
    cdef size_t _acc

    cdef size_t* _context
    cdef uint64_t* _features
    cdef double** beam_scores

    def __cinit__(self, model_dir, feat_set="basic", feat_thresh=5, beam_width=4,
                  clean=False):
        self.model_dir = model_dir
        if clean and os.path.exists(model_dir):
            shutil.rmtree(model_dir)
            os.mkdir(model_dir)
            self.new_idx(model_dir)
        else:
            self.load_idx(model_dir)
            self.guide.load(pjoin(model_dir, 'tagger.gz'), thresh=self.feat_thresh)
        self.feat_thresh = feat_thresh
        self.guide = Perceptron(100, pjoin(model_dir, 'tagger.gz'))
        if not clean:
            self.guide.load(pjoin(model_dir, 'tagger.gz'), thresh=self.feat_thresh)
        #self.features = Extractor(basic, [])
        self.features = Extractor(basic + clusters, [],
                                  bag_of_words=[P1w, P2w, P3w, P4w, P5w, P6w, P7w])
        self.nr_tag = 100
        self.beam_width = beam_width
        self._context = <size_t*>calloc(CONTEXT_SIZE, sizeof(size_t))
        self.max_feats = self.features.nr_template + self.features.nr_bow + 100
        self._features = <uint64_t*>calloc(self.max_feats, sizeof(uint64_t))
        self.beam_scores = <double**>malloc(sizeof(double*) * self.beam_width)
        for i in range(self.beam_width):
            self.beam_scores[i] = <double*>calloc(self.nr_tag, sizeof(double))

    def add_tags(self, Sentences sents):
        cdef size_t i
        n = 0
        self._acc = 0
        for i in range(sents.length):
            self.tag(sents.s[i])
            n += (sents.s[i].length - 2)
        print '%.3f' % (float(self._acc) / n)

    cdef int tag(self, Sentence* sent) except -1:
        cdef TaggerBeam beam = TaggerBeam(None, self.beam_width, sent.length, self.nr_tag)
        cdef size_t p_idx
        cdef TagState* s
        for i in range(sent.length - 1):
            self.fill_beam_scores(beam, sent, i)
            beam.extend_states(self.beam_scores)
        s = <TagState*>beam.beam[0]
        fill_hist(sent.pos, s, sent.length - 1)

    cdef int fill_beam_scores(self, TaggerBeam beam, Sentence* sent,
                              size_t word_i) except -1:
        for i in range(beam.bsize):
            s = <TagState*>beam.beam[i]
            # At this point, beam.clas is the _last_ prediction, not the prediction
            # for this instance
            fill_context(self._context, sent, beam.beam[i].clas, get_p(beam.beam[i]),
                         s.alt, word_i)
            self.features.extract(self._features, self._context)
            self.guide.fill_scores(self._features, self.beam_scores[i])
 
    def train(self, Sentences sents, nr_iter=10):
        self.nr_tag = 0
        tags = set()
        for i in range(sents.length):
            for j in range(sents.s[i].length):
                if sents.s[i].pos[j] >= self.nr_tag:
                    self.nr_tag = sents.s[i].pos[j]
                    tags.add(sents.s[i].pos[j])
        self.nr_tag += 1
        self.guide.set_classes(range(self.nr_tag))
        indices = list(range(sents.length))
        split = len(indices) / 20
        train = indices[split:]
        #train = indices
        heldout = indices[:split]
        best_epoch = 0
        best_acc = 0
        for n in range(nr_iter):
            for i in train:
                self.static_train(n, sents.s[i])
            print_train_msg(n, self.guide.n_corr, self.guide.total, self.guide.cache.n_hit,
                            self.guide.cache.n_miss)
            self.guide.n_corr = 0
            self.guide.total = 0
            if n % 2 == 1 and self.feat_thresh > 1:
                self.guide.prune(self.feat_thresh)
            if n < 3:
                self.guide.reindex()
            random.shuffle(indices)
        self.guide.finalize()

    cdef int static_train(self, int iter_num, Sentence* sent) except -1:
        cdef size_t  i
        cdef double* gscores = <double*>calloc(self.nr_tag, sizeof(double))
        cdef TaggerBeam beam = TaggerBeam(None, self.beam_width, sent.length, self.nr_tag)
        cdef double gscore = 0
        cdef size_t t = 0
        cdef double violn_score = -1
        cdef TagState* violn
        cdef uint64_t** gold_feats = <uint64_t**>malloc(sent.length * sizeof(uint64_t*))
        assert sent.length < 500
        #cdef size_t* gstates = <size_t*>malloc(sent.length * sizeof(size_t))
        for i in range(sent.length - 1):
            self.fill_beam_scores(beam, sent, i)
            beam.extend_states(self.beam_scores)
            gprev = sent.pos[i - 1] if i >= 1 else 0
            gprevprev = sent.pos[i - 2] if i >= 2 else 0
            gold_feats[i] = <uint64_t*>calloc(self.max_feats, sizeof(uint64_t))
            fill_context(self._context, sent, gprev, gprevprev, 0, i)
            self.features.extract(gold_feats[i], self._context)
            self.guide.fill_scores(gold_feats[i], gscores)
            gscore += gscores[sent.pos[i]]
            if (beam.beam[0].score - gscore) > violn_score:
                violn_score = beam.beam[0].score - gscore
                violn = beam.beam[0]
                t = i + 1
                # TODO:  Get the right beam state for the violation!!
            self.guide.n_corr += (sent.pos[i] == beam.beam[0].clas)
            self.guide.total += 1
        cdef size_t* pstates
        if violn != NULL:
            pstates = <size_t*>malloc(violn.length * sizeof(size_t))
            fill_hist(pstates, violn, violn.length)
            counts = self._count_feats(t, sent.pos,
                                       pstates, sent, gold_feats)
            self.guide.batch_update(counts)
        for i in range(sent.length - 1):
            free(gold_feats[i])
        free(gold_feats)
        free(gscores)
        free(pstates)

    cdef dict _count_feats(self, size_t t, size_t* gstates, size_t* pstates,
                           Sentence* sent, uint64_t** gold_feats):
        cdef dict counts = {}
        for clas in range(self.nr_tag):
            counts[clas] = {}
        cdef size_t gclas, gprev, gprevprev, pclas, pprev, pprevprev
        for i in range(t):
            gclas = gstates[i]
            gprevprev = 0
            gprev = gstates[i - 1] if i >= 1 else 0
            gprevprev = gstates[i - 2] if i >= 2 else 0
            pclas = pstates[i]
            pprev = pstates[i - 1] if i >= 1 else 0
            pprevprev = pstates[i - 2] if i >= 2 else 0
            #if gclas == pclas:
            #    continue
            self._inc_feats(counts[gclas], gold_feats[i], 1.0)
            fill_context(self._context, sent, pprev, pprevprev, 0, i)
            self.features.extract(self._features, self._context)
            self._inc_feats(counts[pclas], self._features, -1.0)
        return counts

    cdef int _inc_feats(self, dict counts, uint64_t* feats,
                        double inc) except -1:
        cdef size_t f = 0
        while feats[f] != 0:
            if feats[f] not in counts:
                counts[feats[f]] = 0
            counts[feats[f]] += inc
            f += 1

    def save(self):
        self.guide.save(pjoin(self.model_dir, 'tagger.tgz'))

    def load(self):
        self.guide.load(pjoin(self.model_dir, 'model.gz'), thresh=self.feat_thresh)

    def new_idx(self, model_dir):
        index.hashes.init_word_idx(pjoin(model_dir, 'words'))
        index.hashes.init_pos_idx(pjoin(model_dir, 'pos'))
        index.hashes.init_label_idx(pjoin(model_dir, 'labels'))

    def load_idx(self, model_dir):
        index.hashes.load_word_idx(pjoin(model_dir, 'words'))
        index.hashes.load_pos_idx(pjoin(model_dir, 'pos'))
        index.hashes.load_label_idx(pjoin(model_dir, 'labels'))
 

def print_train_msg(n, n_corr, n_move, n_hit, n_miss):
    pc = lambda a, b: '%.1f' % ((float(a) / (b + 1e-100)) * 100)
    move_acc = pc(n_corr, n_move)
    cache_use = pc(n_hit, n_hit + n_miss + 1e-100)
    msg = "#%d: Moves %d/%d=%s" % (n, n_corr, n_move, move_acc)
    if cache_use != 0:
        msg += '. Cache use %s' % cache_use
    print msg


cdef enum:
    N0w
    N0c
    N0c6
    N0c4
    N0suff
    N0pre

    N0quo

    N1w
    N1c
    N1c6
    N1c4
    N1suff
    N1pre

    P1w
    P1c
    P1c6
    P1c4
    P1suff
    P1pre
    P1p

    P2w
    P2c
    P2c6
    P2c4
    P2suff
    P2pre
    P2p

    P3w # For BOW
    P4w
    P5w
    P6w
    P7w
    CONTEXT_SIZE

#basic = ((N0w,), (P1p,),)

basic = (
    (N0w,),
    (N1w,),
    (P1p,),
    (P2p,),
    (P1p, P2p),
    (P1p, N0w),
    (N0suff,),
    (N0pre,),
    (N1suff,),
    (N1pre,),
    (P1suff,),
    (P1pre,),
    (N0quo,),
    (N0w, N0quo),
    (P1p, N0quo),
)

clusters = (
    (N0c,),
    (N0c4,),
    (N0c6,),
    (P1c,),
    (P1c4,),
    (P1c6,),
    (N1c,),
    (N1c4,),
    (N1c6,),
    (P1c, N0w),
    (P1p, P1c6, N0w),
    (P1c6, N0w),
    (N0w, N1c),
    (N0w, N1c6),
    (N0w, N1c4),
    (P2c4, P1c4, N0w)
)

cdef int fill_context(size_t* context, Sentence* sent, size_t ptag, size_t pptag,
                      size_t p_alt, size_t i):
    context[N0w] = sent.words[i]
    context[N0c] = sent.clusters[i]
    context[N0c6] = sent.cprefix6s[i]
    context[N0c4] = sent.cprefix4s[i]
    context[N0suff] = sent.orths[i]
    context[N0pre] = sent.parens[i]
    
    context[N1w] = sent.words[i + 1]
    context[N1c] = sent.clusters[i + 1]
    context[N1c6] = sent.cprefix6s[i + 1]
    context[N1c4] = sent.cprefix4s[i + 1]
    context[N1suff] = sent.orths[i + 1]
    context[N1pre] = sent.parens[i + 1]

    context[N0quo] = sent.quotes[i] == 0
    if i == 1:
        return 0
    context[P1w] = sent.words[i-1]
    context[P1c] = sent.clusters[i-1]
    context[P1c6] = sent.cprefix6s[i-1]
    context[P1c4] = sent.cprefix4s[i-1]
    context[P1suff] = sent.orths[i-1]
    context[P1pre] = sent.parens[i-1]
    context[P1p] = ptag
    if i == 2:
        return 0
    context[P2w] = sent.words[i-2]
    context[P2c] = sent.clusters[i-2]
    context[P2c6] = sent.cprefix6s[i-2]
    context[P2c4] = sent.cprefix4s[i-2]
    context[P2suff] = sent.orths[i-2]
    context[P2pre] = sent.parens[i-2]
    context[P2p] = pptag

    # Fill bag-of-words slots
    #cdef size_t slot = P3w
    #i -= 2
    #while i > 0 and slot < CONTEXT_SIZE:
    #    i -= 1
    #    context[slot] = sent.words[i]
    #    slot += 1
