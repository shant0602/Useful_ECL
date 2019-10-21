/**
 * ECL module that supports fast, inexact matching of query words against a
 * dictionary of words.  Inexact matching is useful for matching words that
 * differ by only a few characters, perhaps due to typos or transpositions.
 * Very large word sets are fully supported for both dictionary and query
 * words, making this a good big data matching solution in a distributed
 * environment like HPCC.
 *
 * The code here relies on computing the Levenshtein Distance (the
 * "edit distance") between any two words, which is informally defined as
 * the minimum number of single-character edits (insertions, deletions or
 * substitutions) required to change one word into the other.  More
 * information on edit distances can be found at
 * https://en.wikipedia.org/wiki/Levenshtein_distance.
 *
 * This module creates an ECL index that represents the dictionary of words.
 * Query words, either singularly or in the form of a dataset, can then
 * be quickly matched against the dictionary.  The result is a dataset
 * where each record contains a query word, a dictionary word, and the
 * actual edit distance between them.
 *
 * A maximum edit distance ("MaxED") is provided at both index creation
 * time and at search time.  Fuzzy matches with edit distances greater than
 * the search MaxED will not be returned.  The index grows dramatically
 * with higher MaxED values and longer words; a MaxED of 1 or 2 is typical
 * when matching single words.  You can use different MaxED values for index
 * creation and search; the MaxED value for search will be the limit used
 * for results.  Searching with a MaxED higher than the MaxED used to create
 * the index will return only partial results (if any) for any edit distance
 * value beyond the MaxED used for index creation, so for accuracy the MaxED
 * value you use for search should not exceed the value used to create
 * the index.
 *
 * This module supports an "adaptive edit distance" feature.  Rather than
 * setting a fixed maximum edit distance, you can supply a zero value for the
 * MaxED parameter and the function will choose an appropriate value on a
 * per-word basis.  The value chosen will be basically, "1 for every four
 * characters."  So, a three-character word will use a MaxED of 1, a
 * five-character word use a MaxED of 2, and so on.
 *
 * This module provides data normalization only for the TextSearch() function,
 * where it is slightly harder to implement.  For dictionary creation and
 * the other search functions, you should prepare your data by converting the
 * strings to uppercase or lowercase, removing space runs, etc so that all
 * values are normalized as much as possible.  Exactly what normalization
 * steps you perform depend on your use-case.
 *
 * This module does not provide any data normalization, and comparisons are
 * case-sensitive.  You should prepare both the dictionary and query
 * words by upper- or lower-casing all values, removing space runs, etc so
 * that all values are normalized as much as possible.  Exactly what
 * normalization steps you should perform depend on your use-case.
 *
 * Attributes exported by this module (detailed descriptions are inlined with
 * each exported symbol):
 *
 *      // Record Definitions
 *      WordRec
 *      SearchResultRec
 *      TextSearchResultRec
 *
 *      // Function Prototypes
 *      NormalizeWordPrototype()
 *
 *      // Functions -- see code for parameter list
 *      NormalizeWordUpperCase()
 *      CreateIndex()
 *      BulkSearch()
 *      WordSearch()
 *      TextSearch()
 *
 * Example code may be found at the end of this file.
 *
 * The methods used in this module (primarily the "deletion neighborhood"
 * concept) were inspired by a paper written by Daniel Karch, Dennis Luxen,
 * and Peter Sanders from the Karlsruhe Institute of Technology, titled
 * "Improved Fast Similarity Search in Dictionaries"
 * (https://arxiv.org/abs/1008.1191v2).  This paper, in turn, was based on the
 * work described in "Fast Similarity Search in Large Dictionaries" by
 * Thomas Bocek, Ela Hunt, and Burkhard Stiller
 * (https://fastss.csg.uzh.ch/ifi-2007.02.pdf).
 *
 * Origin:  https://github.com/dcamper/Useful_ECL
 */

IMPORT Std;

EXPORT FuzzyStringSearch := MODULE

    // Maximum length of a word we will work with; words exceeding this
    // length will be truncated
    SHARED MAX_WORD_LENGTH := 255;

    // Simple record defining either a dictionary or query word (string)
    EXPORT WordRec := RECORD
        STRING      word;
    END;

    // The record definition of results from BulkSearch() or Search()
    SHARED RelatedWordRec := RECORD
        STRING      dictionary_word;
        UNSIGNED1   edit_distance;
    END;

    // The record definition of results from BulkSearch() or Search()
    EXPORT SearchResultRec := RECORD
        STRING      given_word;
        RelatedWordRec;
    END;

    // The record definition of results from TextSearch()
    EXPORT TextSearchResultRec := RECORD
        UNSIGNED2   word_pos;
        STRING      given_word;
        DATASET(RelatedWordRec)     related_words;
    END;

    // The record definition used by the dictionary index file and by
    // the internal matching function
    SHARED LookupRec := RECORD
        UNSIGNED8   hash_value;     // 64-bit hash value of a word substring
        WordRec;                    // Original word
    END;

    /**
     * Function prototype -- must be overridden with a concrete function
     *
     * Given a single word, return a 'normalized' version of the word to be
     * used for index creation or searching.
     *
     * @param   oneWord     A word to normalize; REQUIRED
     *
     * @return  The given word, normalized in whatever manner is correct
     *          for the current use-case.
     *
     * @see     TextSearch
     * @see     NormalizeWordUpperCase
     */
    EXPORT STRING NormalizeWordPrototype(STRING oneWord);

    /**
     * Concrete instantiation of the NormalizeWordPrototype() prototype
     *
     * @param   oneWord     A word to normalize; REQUIRED
     *
     * @return  The given word converted to uppercase and with leading
     *          and trailing non-alphanumeric characters removed.
     *
     * @see     NormalizeWordPrototype
     * @see     TextSearch
     */
    EXPORT STRING NormalizeWordUpperCase(STRING oneWord) := FUNCTION
        upperWord := Std.Str.ToUpperCase(oneWord);
        noBeginningPunct := REGEXREPLACE('^[^[:alnum:]]+', upperWord, '');
        noEndingPunct := REGEXREPLACE('[^[:alnum:]]+$', noBeginningPunct, '');

        RETURN noEndingPunct;
    END;

    /**
     * Internal helper function.
     *
     * Given a dataset of words and a MaxED value, this function generates
     * a dataset in the layout used for either index creation or searching.
     * For each word, substrings are created and hashed into 64-bit numbers.
     * The number of records generated for each word depends on the length of
     * the word and the max_edit_distance value provided.
     *
     * @param   words               A dataset in WordRec layout containing
     *                              the words to process; this dataset
     *                              should not be empty; REQUIRED
     * @param   max_edit_distance   The maximum edit distance to use when
     *                              creating word substrings; this is
     *                              typically a value of 1 or 2 for single-
     *                              word values, but may be slightly larger
     *                              when dealing with longer "words";
     *                              REQUIRED
     *
     * @return  A new DATASET(LookupRec)
     */
    SHARED DATASET(LookupRec) CreateDeletionNeighborhoodHashes(DATASET(WordRec) words, UNSIGNED1 max_edit_distance) := FUNCTION
        STREAMED DATASET(WordRec) _CreateDeletionNeighborhood(CONST STRING _one_word, UNSIGNED1 _max_distance, UNSIGNED2 _max_word_len = MAX_WORD_LENGTH) := EMBED(C++)
            #option pure;
            #include <string>
            #include <set>
            typedef std::set<std::string> WordSet;

            // Recursive function that deletes single characters; depth here is associated with the
            // the MaxED value
            void PopulateDeletedCharList(const std::string& aWord, unsigned int depth, WordSet& aSet)
            {
                // Abort if we've gone deep enough or if the word is too short
                // (don't allow single-character substrings in the result)
                if (depth > 0 && aWord.size() > 2)
                {
                    for (unsigned int x = 0; x < aWord.size(); x++)
                    {
                        std::string     myWord(aWord);

                        myWord.erase(x, 1);
                        aSet.insert(myWord);
                        PopulateDeletedCharList(myWord, depth - 1, aSet);
                    }
                }
            }

            class StreamDataset : public RtlCInterface, implements IRowStream
            {
                public:

                    StreamDataset(IEngineRowAllocator* _resultAllocator, unsigned int wordLen, const char* word, unsigned int max_edit_distance)
                        : resultAllocator(_resultAllocator), myWord(word, wordLen), isInited(false)
                    {
                        myEditDistance = (max_edit_distance > 0 ? max_edit_distance : (wordLen - 1) / 4 + 1);
                        isStopped = (wordLen == 0);
                    }

                    RTLIMPLEMENT_IINTERFACE

                    // Each time a row is requested, provide a copy of the next
                    // substring created during object construction
                    virtual const void* nextRow()
                    {
                        if (isStopped)
                        {
                            return NULL;
                        }

                        if (!isInited)
                        {
                            // Insert given word as-is into our substring set
                            deleteSet.insert(myWord);

                            // Build substrings and insert them into our substring set
                            PopulateDeletedCharList(myWord, myEditDistance, deleteSet);

                            deleteSetIter = deleteSet.begin();
                            isInited = true;
                        }

                        if (deleteSetIter != deleteSet.end())
                        {
                            const std::string&      oneWord(*deleteSetIter);
                            RtlDynamicRowBuilder    rowBuilder(resultAllocator);
                            unsigned int            len = sizeof(size32_t) + oneWord.size();
                            byte*                   row = rowBuilder.ensureCapacity(len, NULL);

                            *(size32_t*)(row) = oneWord.size();
                            row += sizeof(size32_t);
                            memcpy(row, oneWord.data(), oneWord.size());

                            ++deleteSetIter;

                            return rowBuilder.finalizeRowClear(len);
                        }

                        isStopped = true;

                        return NULL;
                    }

                    virtual void stop()
                    {
                        isStopped = true;
                    }

                protected:

                    Linked<IEngineRowAllocator> resultAllocator;

                private:

                    std::string                 myWord;         // Word we are processing
                    unsigned int                myEditDistance; // The edit distance we're calculating
                    WordSet                     deleteSet;      // Contains unique substrings
                    WordSet::const_iterator     deleteSetIter;  // Iterator used to track items for nextRow()
                    bool                        isInited;
                    bool                        isStopped;
            };

            #body

            return new StreamDataset(_resultAllocator, std::min(len_one_word, (size32_t)_max_word_len), _one_word, _max_distance);
        ENDEMBED;

        // Collect substrings for each word and hash them,
        // flattening the result; note that results from
        // _CreateDeletionNeighborhood() are deduplicated
        // and non-empty
        result := NORMALIZE
            (
                words,
                _CreateDeletionNeighborhood(LEFT.word, max_edit_distance),
                TRANSFORM
                (
                    LookupRec,
                    SELF.hash_value := HASH64(RIGHT.word),
                    SELF.word := LEFT.word
                )
            );

        RETURN result;
    END;

    /**
     * Internal helper definition
     *
     * @param   path    Full logical pathname to the dictionary index file;
     *                  index may be physically present or not; REQUIRED
     *
     * @return  INDEX definition
     *
     * @see     CreateIndex
     * @see     BulkSearch
     * @see     Search
     */
    SHARED HashLookupIndexDef(STRING path) := INDEX
        (
            {LookupRec.hash_value},
            {LookupRec},
            path,
            OPT
        );

    /**
     * Create an index file representing a dictionary of words.  This index
     * will be used later when comparing query words.  Only words that are
     * at least three characters in length will have index entries suitable
     * for edit distance searching.
     *
     * @param   words               A dataset in WordRec layout containing
     *                              the words to process; words are
     *                              deduplicated; this dataset should not
     *                              be empty; REQUIRED
     * @param   newIndexPath        Full logical path of the index file to
     *                              create; any existing file of the same
     *                              name will be deleted; REQUIRED
     * @param   maxEditDistance     The maximum edit distance this index
     *                              file will support; this is
     *                              typically a value of 1 or 2 for single-
     *                              word values, but may be slightly larger
     *                              when dealing with longer "words";
     *                              a value of zero will enable an 'adaptive
     *                              edit distance' which means that the value
     *                              for any single word will depend on the
     *                              length of that word (roughly, 1 for every
     *                              four characters); OPTIONAL, defaults to 1
     *
     * @return  An action that creates a new index file.
     *
     * @see     BulkSearch
     * @see     WordSearch
     */
    EXPORT CreateIndex(DATASET(WordRec) words,
                       STRING newIndexPath,
                       UNSIGNED1 maxEditDistance = 1) := FUNCTION
        uniqueWords := TABLE(words(word != ''), {word}, word, MERGE);
        lookupData := CreateDeletionNeighborhoodHashes(uniqueWords, maxEditDistance);
        indexDef := HashLookupIndexDef(newIndexPath);

        RETURN BUILD(indexDef, lookupData, OVERWRITE);
    END;

    /**
     * Attempt to match a dataset of query words against a dictionary
     * represented by an index file previously created with CreateIndex().
     * Only words that are at least three characters in length will have
     * edit distance searching performed (shorter words will have only exact
     * matching).
     *
     * @param   words               A dataset in WordRec layout containing
     *                              the query words to match; words are
     *                              deduplicated; this dataset should not
     *                              be empty; REQUIRED
     * @param   indexPath           Full logical path of the index file
     *                              containing the dictionary words, previously
     *                              created with a call to CreateIndex();
     *                              REQUIRED
     * @param   maxEditDistance     The maximum edit distance to use when
     *                              comparing query words to dictionary words;
     *                              a value of zero will enable an 'adaptive
     *                              edit distance' which means that the value
     *                              for any single word will depend on the
     *                              length of that word (roughly, 1 for every
     *                              four characters); OPTIONAL, defaults to 1
     *
     * @return  A new DATASET(SearchResultRec) containing any matches.  Note
     *          that only those query words with matches from the dictionary
     *          will appearin the result.
     *
     * @see     SearchResultRec
     * @see     CreateIndex
     * @see     WordSearch
     */
    EXPORT DATASET(SearchResultRec) BulkSearch(DATASET(WordRec) words,
                                               STRING indexPath,
                                               UNSIGNED1 maxEditDistance = 1) := FUNCTION
        uniqueWords := TABLE(words(word != ''), {word}, word, MERGE);
        wordHashes := CreateDeletionNeighborhoodHashes(uniqueWords, maxEditDistance);
        indexDef := HashLookupIndexDef(indexPath);

        initialResult := JOIN
            (
                wordHashes,
                indexDef,
                LEFT.hash_value = RIGHT.hash_value,
                TRANSFORM
                    (
                        SearchResultRec,
                        distance := Std.Str.EditDistance(LEFT.word, RIGHT.word);
                        SELF.edit_distance := MAP
                            (
                                maxEditDistance > 0 AND distance <= maxEditDistance                     =>  distance,
                                maxEditDistance = 0 AND distance <= ((LENGTH(LEFT.word) - 1) DIV 4 + 1) =>  distance,
                                SKIP
                            ),
                        SELF.given_word := LEFT.word,
                        SELF.dictionary_word := RIGHT.word
                    ),
                LIMIT(0)
            );

        dedupedResult := TABLE
            (
                initialResult,
                {
                    given_word,
                    dictionary_word,
                    edit_distance
                },
                given_word, dictionary_word, edit_distance,
                MERGE
            );

        RETURN PROJECT(dedupedResult, SearchResultRec);
    END;

    /**
     * Attempt to match a single query word against a dictionary represented
     * by an index file previously created with CreateIndex().  The query word
     * must be at least three characters in length to be searched with the
     * edit distance algorithm (a shorter word will have only exact matching).
     *
     * @param   word                The query word to match; should not be an
     *                              empty string; REQUIRED
     * @param   indexPath           Full logical path of the index file
     *                              containing the dictionary words, previously
     *                              created with a call to CreateIndex();
     *                              REQUIRED
     * @param   maxEditDistance     The maximum edit distance to use when
     *                              comparing the given word to dictionary
     *                              words; a value of zero will enable an
     *                              'adaptive edit distance' which means that
     *                              the value will depend on the length of
     *                              the given word (roughly, 1 for every
     *                              four characters); OPTIONAL, defaults to 1
     *
     * @return  A new DATASET(SearchResultRec) containing any matches.  If there
     *          is no match found then an empty dataset will be returned.
     *
     * @see     SearchResultRec
     * @see     CreateIndex
     * @see     BulkSearch
     */
    EXPORT DATASET(SearchResultRec) WordSearch(STRING word,
                                               STRING indexPath,
                                               UNSIGNED1 maxEditDistance = 1) := FUNCTION
        RETURN BulkSearch(DATASET([word], WordRec), indexPath, maxEditDistance);
    END;

    /**
     * Attempt to match words within with a string against a dictionary
     * represented by an index file previously created with CreateIndex().
     * The string can contain one or more words, delimited by spaces.
     * Only words that are at least three characters in length will have
     * edit distance searching performed (shorter words will have only exact
     * matching).
     *
     * Each word that is extracted from the string must be normalized using
     * the function you provide as an argument to this function call.  A
     * default normalization function is provided that uppercases the word
     * and removes leading and trailing non-alphanumeric characters.
     *
     * If the desire is to search multi-word strings as a whole, without
     * breaking them up into individual words, then BulkSearch() or
     * WordSearch() should be used instead.
     *
     * @param   text                A string containing one or more words;
     *                              each word is processed through the
     *                              function defined by the normWordFunction
     *                              argument; REQUIRED
     * @param   indexPath           Full logical path of the index file
     *                              containing the dictionary words, previously
     *                              created with a call to CreateIndex();
     *                              REQUIRED
     * @param   normWordFunction    The function called for each word extracted
     *                              from the text argument to normalize its
     *                              value for searching; OPTIONAL, defaults
     *                              to a function that uppercases the string
     *                              and removes leading and trailing non-
     *                              alphanumeric characters
     * @param   maxEditDistance     The maximum edit distance to use when
     *                              comparing each word to dictionary words;
     *                              a value of zero will enable an 'adaptive
     *                              edit distance' which means that the value
     *                              for any single word will depend on the
     *                              length of that word (roughly, 1 for every
     *                              four characters); OPTIONAL, defaults to 1
     *
     * @return  A new DATASET(TextSearchResultRec) dataset containing all of
     *          original words, their relative positions within the string,
     *          and a child dataset for each showing any possible matches
     *          (possibly none) from the dictionary
     *
     * @see     CreateIndex
     * @see     BulkSearch
     * @see     WordSearch
     */
    EXPORT TextSearch(STRING text,
                      STRING indexPath,
                      NormalizeWordPrototype normWordFunction = NormalizeWordUpperCase,
                      UNSIGNED1 maxEditDistance = 1) := FUNCTION
        wordSet := Std.Str.SplitWords(text, ' ');

        PositionWordRec := RECORD(WordRec)
            UNSIGNED2   word_pos;
        END;

        wordDS := PROJECT
            (
                DATASET(wordSet, {STRING w}),
                TRANSFORM
                    (
                        PositionWordRec,
                        SELF.word_pos := COUNTER,
                        SELF.word := normWordFunction(LEFT.w)
                    )
            );

        bulkResults := BulkSearch(wordDS, indexPath, maxEditDistance);

        res := DENORMALIZE
            (
                wordDS,
                bulkResults,
                LEFT.word = RIGHT.given_word,
                GROUP,
                TRANSFORM
                    (
                        TextSearchResultRec,
                        SELF.word_pos := LEFT.word_pos,
                        SELF.given_word := LEFT.word,
                        SELF.related_words := PROJECT(ROWS(RIGHT), RelatedWordRec),
                        SELF := LEFT
                    ),
                LEFT OUTER
            );
        RETURN res;
    END;

END;

/*****************************************************************************

// Example:  Create a dictionary index file

IMPORT FuzzyStringSearch;

dictionaryWords := DATASET
    (
        ['THE', 'QUICK', 'BROWN', 'FOX', 'JUMPED', 'OVER', 'THE', 'LAZY', 'DOG'],
        FuzzyStringSearch.WordRec
    );

FuzzyStringSearch.CreateIndex
    (
        dictionaryWords,
        '~fuzzy_search::demo_idx',
        maxEditDistance := 1
    );

*/

/*****************************************************************************

// Example:  Bulk search against the dictionary index file

IMPORT FuzzyStringSearch;

queryWords := DATASET
    (
        ['THE', 'QUIK', 'BROWNN', 'FAX', 'JUMPED', 'UNDER', 'THE', 'LAZY', 'LOG'],
        FuzzyStringSearch.WordRec
    );

results := FuzzyStringSearch.BulkSearch
    (
        queryWords,
        '~fuzzy_search::demo_idx',
        maxEditDistance := 1
    );

OUTPUT(results);

// given_word      dictionary_word     edit_distance
//--------------------------------------------------
// LOG             DOG                 1
// FAX             FOX                 1
// JUMPED          JUMPED              0
// THE             THE                 0
// BROWNN          BROWN               1
// LAZY            LAZY                0
// QUIK            QUICK               1

*/

/*****************************************************************************

// Example:  Single-word search against the dictionary index file

IMPORT FuzzyStringSearch;

results := FuzzyStringSearch.WordSearch
    (
        'QUIK',
        '~fuzzy_search::demo_idx',
        maxEditDistance := 1
    );

OUTPUT(results);

// given_word      dictionary_word     edit_distance
//--------------------------------------------------
// QUIK            QUICK               1

*/

/*****************************************************************************

// Example:  Text search against the dictionary index file

IMPORT FuzzyStringSearch;

results := FuzzyStringSearch.TextSearch
    (
        'Fax me the big box picture.',
        '~fuzzy_search::demo_idx',
        maxEditDistance := 1
    );

OUTPUT(SORT(results, word_pos));

//                           related_words
// word_pos  given_word      dictionary_word     edit_distance
//------------------------------------------------------------
// 1         FAX             FOX                 1
// 2         ME
// 3         THE             THE                 0
// 4         BIG
// 5         BOX             FOX                 1
// 6         PICTURE

*/
