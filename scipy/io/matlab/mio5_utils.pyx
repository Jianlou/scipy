''' Cython mio5 utility routines (-*- python -*- like)

'''

'''
Programmer's notes
------------------
Routines here have been reasonably optimized.

The char matrix reading is not very fast, but it's not usually a
bottleneck. See comments in ``read_char`` for possible ways to go if you
want to optimize.
'''

import sys

from copy import copy as pycopy

from python cimport Py_INCREF, Py_DECREF
from python_object cimport PyObject

cdef extern from "Python.h":
    ctypedef struct PyTypeObject:
        pass

from python_string cimport PyString_Size, PyString_FromString, \
    PyString_FromStringAndSize

import numpy as np
cimport numpy as cnp

cdef extern from "numpy/arrayobject.h":
    PyTypeObject PyArray_Type
    cnp.ndarray PyArray_NewFromDescr(PyTypeObject *subtype,
                                     cnp.dtype newdtype,
                                     int nd,
                                     cnp.npy_intp* dims,
                                     cnp.npy_intp* strides,
                                     void* data,
                                     int flags,
                                     object parent)

cdef extern from "numpy_rephrasing.h":
    void PyArray_Set_BASE(cnp.ndarray arr, object obj)

# Numpy must be initialized before any code using the numpy C-API
# directly
cnp.import_array()

# Constant from numpy - max number of array dimensions
DEF _MAT_MAXDIMS = 32
# max number of integer indices of matlab data types (miINT8 etc)
DEF _N_MIS = 20
# max number of integer indices of matlab class types (mxINT8_CLASS etc)
DEF _N_MXS = 20

cimport streams
cimport mio_utils as cmio_utils
import scipy.io.matlab.miobase as miob
from scipy.io.matlab.mio_utils import FileReadOpts, process_element
import scipy.io.matlab.mio5_params as mio5p
import scipy.sparse


cdef enum:
    miINT8 = 1
    miUINT8 = 2
    miINT16 = 3
    miUINT16 = 4
    miINT32 = 5
    miUINT32 = 6
    miSINGLE = 7
    miDOUBLE = 9
    miINT64 = 12
    miUINT64 = 13
    miMATRIX = 14
    miCOMPRESSED = 15
    miUTF8 = 16
    miUTF16 = 17
    miUTF32 = 18

cdef enum: # see comments in mio5_params
    mxCELL_CLASS = 1
    mxSTRUCT_CLASS = 2
    mxOBJECT_CLASS = 3
    mxCHAR_CLASS = 4
    mxSPARSE_CLASS = 5
    mxDOUBLE_CLASS = 6
    mxSINGLE_CLASS = 7
    mxINT8_CLASS = 8
    mxUINT8_CLASS = 9
    mxINT16_CLASS = 10
    mxUINT16_CLASS = 11
    mxINT32_CLASS = 12
    mxUINT32_CLASS = 13
    mxINT64_CLASS = 14
    mxUINT64_CLASS = 15
    mxFUNCTION_CLASS = 16
    mxOPAQUE_CLASS = 17 # This appears to be a function workspace
    mxOBJECT_CLASS_FROM_MATRIX_H = 18

sys_is_le = sys.byteorder == 'little'
native_code = sys_is_le and '<' or '>'
swapped_code = sys_is_le and '>' or '<'


cpdef cnp.uint32_t byteswap_u4(cnp.uint32_t u4):
    return ((u4 << 24) |
           ((u4 << 8) & 0xff0000U) |
           ((u4 >> 8 & 0xff00u)) |
           (u4 >> 24))


cdef class VarHeader5:
    cdef readonly object name
    cdef int mclass
    cdef object dims
    cdef cnp.int32_t dims_ptr[_MAT_MAXDIMS]
    cdef int n_dims
    cdef int is_complex
    cdef int is_logical
    cdef public int is_global
    cdef size_t nzmax


cdef class VarReader5:
    cdef public int is_swapped, little_endian
    cdef int struct_as_record
    cdef object codecs, uint16_codec
    # process_element options
    cdef cmio_utils.FileReadOpts read_opts
    # c-optimized version of reading stream
    cdef streams.GenericStream cstream
    # pointers to stuff in preader.dtypes
    cdef PyObject* dtypes[_N_MIS]
    # pointers to stuff in preader.class_dtypes
    cdef PyObject* class_dtypes[_N_MXS]
    # necessary to keep memory alive for .dtypes, .class_dtypes
    cdef object preader
    # cached here for convenience in later array creation
    cdef cnp.dtype U1_dtype
    cdef cnp.dtype bool_dtype
    
    def __new__(self, preader):
        self.is_swapped = preader.byte_order == swapped_code
        if self.is_swapped:
            self.little_endian = not sys_is_le
        else:
            self.little_endian = sys_is_le
        # option affecting reading of matlab struct arrays
        self.struct_as_record = preader.struct_as_record
        # store codecs for text matrix reading
        self.codecs = preader.codecs
        self.uint16_codec = preader.uint16_codec
        # set c-optimized stream object from python file-like object
        self.set_stream(preader.mat_stream)
        # options structure for process_element
        self.read_opts = FileReadOpts(
            preader.chars_as_strings,
            preader.mat_dtype,
            preader.squeeze_me)
        # copy refs to dtypes into object pointer array. Store preader
        # to keep preader.dtypes, class_dtypes alive. We only need the
        # integer-keyed dtypes
        self.preader = preader
        for key, dt in preader.dtypes.items():
            if isinstance(key, basestring):
                continue
            self.dtypes[key] = <PyObject*>dt
        # copy refs to class_dtypes into object pointer array
        for key, dt in preader.class_dtypes.items():
            if isinstance(key, basestring):
                continue
            self.class_dtypes[key] = <PyObject*>dt
        # cache correctly byte ordered dtypes
        if self.little_endian:
            self.U1_dtype = np.dtype('<U1')
        else:
            self.U1_dtype = np.dtype('>U1')
        bool_dtype = np.dtype('bool')
        
    def set_stream(self, fobj):
        ''' Set stream of best type from file-like `fobj`

        Called from Python when initiating a variable read
        '''
        self.cstream = streams.make_stream(fobj)
        
    def read_tag(self):
        ''' Read tag mdtype and byte_count

        Does necessary swapping and takes account of SDE formats.

        See also ``read_full_tag`` method.
        
        Returns
        -------
        mdtype : int
           matlab data type code
        byte_count : int
           number of bytes following that comprise the data
        tag_data : None or str
           Any data from the tag itself.  This is None for a full tag,
           and string length `byte_count` if this is a small data
           element.
        '''
        cdef cnp.uint32_t mdtype, byte_count
        cdef char tag_ptr[4]
        cdef int tag_res
        cdef object tag_data = None
        tag_res = self.cread_tag(&mdtype, &byte_count, tag_ptr)
        if tag_res == 2: # sde format
            tag_data = tag_ptr[:byte_count]
        return (mdtype, byte_count, tag_data)

    cdef int cread_tag(self,
                     cnp.uint32_t *mdtype_ptr,
                     cnp.uint32_t *byte_count_ptr,
                     char *data_ptr) except -1:
        ''' Read tag mdtype and byte_count

        Does necessary swapping and takes account of SDE formats

        Data may be returned in data_ptr, if this was an SDE

        Returns 1 for success, full format; 2 for success, SDE format; -1
        if error arises
        '''
        cdef cnp.uint16_t mdtype_sde, byte_count_sde
        cdef cnp.uint32_t mdtype
        cdef cnp.uint32_t* u4_ptr = <cnp.uint32_t*>data_ptr
        cdef cnp.uint32_t u4s[2]
        # First read 8 bytes.  The 8 bytes can be in one of two formats.
        # For the first - standard format - the 8 bytes are two uint32
        # values, of which the first is the integer code for the matlab
        # data type (*mdtype*), and the second is the number of bytes of
        # that data type that follow (*byte_count*).  Thus, if the
        # ``mdtype`` is 4 (miDOUBLE), and the ``byte_count`` is 12, then
        # there will follow 3 double values.  The alternative format is
        # "small data element". The first four bytes contain the
        # ``byte_count`` and the ``mdtype``, but as uint16.  The
        # arrangement of the ``byte_count`` and ``mdtype`` is a little
        # complex, see below. The following 4 bytes of the 8 bytes
        # contain the data.  For example, the ``mdtype`` might be 2
        # (miUINT8), and the byte count is 3, and the data is in a
        # string ``tag``, then the contained matrix is length 3, type
        # uint8, where values are ``tag[4], tag[5], tag[6]``.
        #
        # The following paragraph describes the extraction of ``mdtype``
        # and ``byte_count`` for the small data element format.  The
        # following is somewhat contrary to the matlab documentation,
        # but seems to be true of actual .mat files.
        #
        # If the *file* is big endian, then the first four bytes of the
        # tag are two big-endian uint16 values, first ``byte_count`` and
        # second ``mdtype``.  If the *file* is little-endian then the
        # first four bytes are two little-endian uint16 values, first
        # ``mdtype`` and second ``byte_count``.
        self.cstream.read_into(<void *>u4s, 8)
        if self.is_swapped:
            mdtype = byteswap_u4(u4s[0])
        else:
            mdtype = u4s[0]
        # The most significant two bytes of a U4 *mdtype* will always be
        # 0, if they are not, this must be SDE format
        byte_count_sde = mdtype >> 16
        if byte_count_sde: # small data element format
            mdtype_sde = mdtype & 0xffff
            if byte_count_sde > 4:
                raise ValueError('Error in SDE format data')
                return -1
            u4_ptr[0] = u4s[1]
            mdtype_ptr[0] = mdtype_sde
            byte_count_ptr[0] = byte_count_sde
            return 2
        # regular element
        if self.is_swapped:
            byte_count_ptr[0] = byteswap_u4(u4s[1])
        else:
            byte_count_ptr[0] = u4s[1]
        mdtype_ptr[0] = mdtype
        u4_ptr[0] = 0
        return 1

    cdef object read_element(self,
                             cnp.uint32_t *mdtype_ptr,
                             cnp.uint32_t *byte_count_ptr,
                             void **pp,
                             int copy=True):
        ''' Read data element into string buffer, return buffer

        The element is the atom of the matlab file format.

        Parameters
        ----------
        mdtype_ptr : uint32_t*
           pointer to uint32_t value to which we write the mdtype value
        byte_count_ptr : uint32_t*
           pointer to uint32_t value to which we write the byte count
        pp : void**
           pointer to void*. pp[0] will be set to point to the start of
           the returned string memory
        copy : int
           If not 0, do any copies required to allow memory to be freely
           altered without interfering with other objects.  Otherwise
           return string that should not be written to, therefore saving
           unnecessary copies

        Return
        ------
        data : str
           Python string object containing read data

        Notes
        -----
        See ``read_element_into`` for routine to read element into a
        pre-allocated block of memory.  
        '''
        cdef cnp.uint32_t mdtype, byte_count
        cdef char tag_data[4]
        cdef object data
        cdef int mod8
        cdef int tag_res = self.cread_tag(mdtype_ptr,
                                          byte_count_ptr,
                                          tag_data)
        mdtype = mdtype_ptr[0]
        byte_count = byte_count_ptr[0]
        if tag_res == 1: # full format
            data = self.cstream.read_string(
                byte_count,
                pp,
                copy)
            # Seek to next 64-bit boundary
            mod8 = byte_count % 8
            if mod8:
                self.cstream.seek(8 - mod8, 1)
        else: # SDE format, make safer home for data
            data = PyString_FromStringAndSize(tag_data, byte_count)
            pp[0] = <char *>data
        return data

    cdef void read_element_into(self,
                                cnp.uint32_t *mdtype_ptr,
                                cnp.uint32_t *byte_count_ptr,
                                void *ptr):
        ''' Read element into pre-allocated memory in `ptr`

        Parameters
        ----------
        mdtype_ptr : uint32_t*
           pointer to uint32_t value to which we write the mdtype value
        byte_count_ptr : uint32_t*
           pointer to uint32_t value to which we write the byte count
        ptr : void*
           memory location into which to read.  Memory is assumed large
           enough to contain read data

        Returns
        -------
        void

        Notes
        -----
        Compare ``read_element``.
        '''
        cdef:
           int mod8
        cdef int res = self.cread_tag(
            mdtype_ptr,
            byte_count_ptr,
            <char *>ptr)
        cdef cnp.uint32_t byte_count = byte_count_ptr[0]
        if res == 1: # full format
            res = self.cstream.read_into(ptr, byte_count)
            # Seek to next 64-bit boundary
            mod8 = byte_count % 8
            if mod8:
                self.cstream.seek(8 - mod8, 1)
    
    cpdef inline cnp.ndarray read_numeric(self, int copy=True):
        ''' Read numeric data element into ndarray

        Reads element, then casts to ndarray. 

        The type of the array is given by the ``mdtype`` returned via
        ``read_element``. 
        '''
        cdef cnp.uint32_t mdtype, byte_count
        cdef void *data_ptr
        cdef cnp.npy_intp el_count
        cdef cnp.ndarray el
        cdef object data = self.read_element(
            &mdtype, &byte_count, <void **>&data_ptr, copy)
        cdef cnp.dtype dt = <cnp.dtype>self.dtypes[mdtype]
        el_count = byte_count // dt.itemsize
        cdef char * tmp = data
        Py_INCREF(<object> dt)
        el = PyArray_NewFromDescr(&PyArray_Type,
                                   dt,
                                   1,
                                   &el_count,
                                   NULL,
                                   <void*>data_ptr,
                                   0,
                                   <object>NULL)
        Py_INCREF(<object> data)
        PyArray_Set_BASE(el, data)
        return el
            
    cdef inline object read_int8_string(self):
        ''' Read, return int8 type string

        int8 type strings used for variable names, class names of
        objects, and field names of structs and objects.

        Specializes ``read_element``
        '''
        cdef:
            cnp.uint32_t mdtype, byte_count
            void *ptr
            object data
        data = self.read_element(&mdtype, &byte_count, &ptr)
        if mdtype != miINT8:
            raise TypeError('Expecting miINT8 as data type')
        return data

    cdef int read_into_int32s(self, cnp.int32_t *int32p) except -1:
        ''' Read int32 values into pre-allocated memory

        Byteswap as necessary.  Specializes ``read_element_into``

        Parameters
        ----------
        int32p : int32 pointer

        Returns
        -------
        n_ints : int
           Number of integers read
        '''
        cdef:
            cnp.uint32_t mdtype, byte_count
            int i
        self.read_element_into(&mdtype, &byte_count, <void *>int32p)
        if mdtype != miINT32:
            raise TypeError('Expecting miINT32 as data type')
            return -1
        cdef int n_ints = byte_count // 4
        if self.is_swapped:
            for i in range(n_ints):
                int32p[i] = byteswap_u4(int32p[i])
        return n_ints

    def read_full_tag(self):
        ''' Python method for reading full u4, u4 tag from stream

        Returns
        -------
        mdtype : int32
           matlab data type code
        byte_count : int32
           number of data bytes following

        Notes
        -----
        Assumes tag is in fact full, that is, is not a small data
        element.  This means it can skip some checks and makes it
        slightly faster than ``read_tag``
        '''
        cdef cnp.uint32_t mdtype, byte_count
        self.cread_full_tag(&mdtype, &byte_count)
        return mdtype, byte_count

    cdef void cread_full_tag(self,
                        cnp.uint32_t* mdtype,
                        cnp.uint32_t* byte_count):
        ''' C method for reading full u4, u4 tag from stream'''
        cdef cnp.uint32_t u4s[2]
        self.cstream.read_into(<void *>u4s, 8)
        if self.is_swapped:
            mdtype[0] = byteswap_u4(u4s[0])
            byte_count[0] = byteswap_u4(u4s[1])
        else:
            mdtype[0] = u4s[0]
            byte_count[0] = u4s[1]

    cpdef VarHeader5 read_header(self):
        ''' Return matrix header for current stream position

        Returns matrix headers at top level and sub levels
        '''
        cdef:
            cdef cnp.uint32_t u4s[2]
            cnp.uint32_t mdtype, byte_count
            cnp.uint32_t flags_class, nzmax
            cnp.uint16_t mc
            int ret, i
            void *ptr
            VarHeader5 header
        # Read and discard mdtype and byte_count
        self.cstream.read_into(<void *>u4s, 8)
        # get array flags and nzmax
        self.cstream.read_into(<void *>u4s, 8)
        if self.is_swapped:
            flags_class = byteswap_u4(u4s[0])
            nzmax = byteswap_u4(u4s[1])
        else:
            flags_class = u4s[0]
            nzmax = u4s[1]
        header = VarHeader5()
        mc = flags_class & 0xFF
        # Might want to detect unreadable mclasses (such as functions)
        # here and divert to something that preserves the binary data.
        # For now we bail later in read_array_mdtype, via
        # read_mi_matrix, giving a MatReadError
        header.mclass = mc
        header.is_logical = flags_class >> 9 & 1
        header.is_global = flags_class >> 10 & 1
        header.is_complex = flags_class >> 11 & 1
        header.nzmax = nzmax
        header.n_dims = self.read_into_int32s(header.dims_ptr)
        if header.n_dims > _MAT_MAXDIMS:
            raise ValueError('Too many dimensions (%d) for numpy arrays'
                             % header.n_dims)
        # convert dims to list
        header.dims = []
        for i in range(header.n_dims):
            header.dims.append(header.dims_ptr[i])
        header.name = self.read_int8_string()
        return header

    cdef inline size_t size_from_header(self, VarHeader5 header):
        ''' Supporting routine for calculating array sizes from header

        Probably unnecessary optimization that uses integers stored in
        header rather than ``header.dims`` that is a python list.

        Parameters
        ----------
        header : VarHeader5
           array header

        Returns
        -------
        size : size_t
           size of array referenced by header (product of dims)
        '''
        # calculate number of items in array from dims product
        cdef size_t size = 1
        for i in range(header.n_dims):
            size *= header.dims_ptr[i]
        return size

    def array_from_header(self, VarHeader5 header):
        '''Read array from stream, given array header

        Apply standard processing of array given ``read_opts`` options
        set in ``self``.

        Only called at the top level - that is, at when we start
        reading of each variable in the mat file. 
        '''
        arr, mat_dtype = self.read_array_mdtype(header)
        if header.mclass == mxSPARSE_CLASS:
            # no current processing makes sense for sparse
            return arr
        return process_element(arr, self.read_opts, mat_dtype)

    cdef cnp.ndarray read_mi_matrix(self):
        ''' Read header with matrix at sub-levels

        Combines ``read_header`` and functionality of
        ``array_from_header``.  Applies standard processing of array
        given ``read_opts`` options set in self. 
        '''
        cdef:
            VarHeader5 header
            cnp.uint32_t mdtype, byte_count
            object arr, mat_dtype
        # read full tag
        self.cread_full_tag(&mdtype, &byte_count)
        if mdtype != miMATRIX:
            raise TypeError('Expecting matrix here')
        if byte_count == 0: # empty matrix
            mat_dtype = 'f8'
            arr = np.array([[]])
        else:
            header = self.read_header()
            arr, mat_dtype = self.read_array_mdtype(header)
        if header.mclass == mxSPARSE_CLASS:
            # no current processing makes sense for sparse
            return arr
        return process_element(arr, self.read_opts, mat_dtype)

    cpdef read_array_mdtype(self, VarHeader5 header):
        ''' Read array of any type, return array and mat_dtype

        Parameters
        ----------
        header : VarHeader5
           array header object

        Returns
        -------
        arr : array or sparse array
           read array
        mat_dtype : None or dtype
           dtype of array as it would be read into matlab workspace, or
           None if it does not make sense that this would differ from
           the dtype of `arr`
        '''
        cdef:
            object arr
        cdef int mc = header.mclass
        cdef object mat_dtype = None
        if (mc == mxDOUBLE_CLASS
            or mc == mxSINGLE_CLASS
            or mc == mxINT8_CLASS
            or mc == mxUINT8_CLASS
            or mc == mxINT16_CLASS
            or mc == mxUINT16_CLASS
            or mc == mxINT32_CLASS
            or mc == mxUINT32_CLASS
            or mc == mxINT64_CLASS
            or mc == mxUINT64_CLASS): # numeric matrix
            if header.is_logical:
                mat_dtype = self.bool_dtype
            else:
                mat_dtype = <object>self.class_dtypes[mc]
            arr = self.read_real_complex(header)
        elif mc == mxSPARSE_CLASS:
            arr = self.read_sparse(header)
        elif mc == mxCHAR_CLASS:
            arr = self.read_char(header)
        elif mc == mxCELL_CLASS:
            arr = self.read_cells(header)
        elif mc == mxSTRUCT_CLASS:
            arr = self.read_struct(header)
        elif mc == mxOBJECT_CLASS: # like structs, but with classname
            classname = self.read_int8_string()
            arr = self.read_struct(header)
            arr = mio5p.MatlabObject(arr, classname)
        elif mc == mxFUNCTION_CLASS:
            raise miob.MatReadError('Cannot read matlab functions')
        return arr, mat_dtype

    cpdef cnp.ndarray read_real_complex(self, VarHeader5 header):
        ''' Read real / complex matrices from stream '''
        cdef:
            cnp.ndarray res, res_j
        if header.is_complex:
            # avoid array copy to save memory
            res = self.read_numeric(False)
            res_j = self.read_numeric(False)
            res = res + (res_j * 1j)
        else:
            res = self.read_numeric()
        return res.reshape(header.dims[::-1]).T

    cdef object read_sparse(self, VarHeader5 header):
        ''' Read sparse matrices from stream '''
        cdef cnp.ndarray rowind, indptr, data, data_j
        cdef size_t M, N, nnz
        rowind = self.read_numeric()
        indptr = self.read_numeric()
        if header.is_complex:
            # avoid array copy to save memory
            data   = self.read_numeric(False)
            data_j = self.read_numeric(False)
            data = data + (data_j * 1j)
        else:
            data = self.read_numeric()
        ''' From the matlab (TM) API documentation, last found here:
        http://www.mathworks.com/access/helpdesk/help/techdoc/matlab_external/
        rowind are simply the row indices for all the (nnz) non-zero
        entries in the sparse array.  rowind has nzmax entries, so
        may well have more entries than nnz, the actual number of
        non-zero entries, but rowind[nnz:] can be discarded and
        should be 0. indptr has length (number of columns + 1), and
        is such that, if D = diff(colind), D[j] gives the number of
        non-zero entries in column j. Because rowind values are
        stored in column order, this gives the column corresponding
        to each rowind
        '''
        M,N = header.dims
        indptr = indptr[:N+1]
        nnz = indptr[-1]
        rowind = rowind[:nnz]
        data   = data[:nnz]
        return scipy.sparse.csc_matrix(
            (data,rowind,indptr),
            shape=(M,N))
                
    cpdef cnp.ndarray read_char(self, VarHeader5 header):
        ''' Read char matrices from stream as arrays

        Matrices of char are likely to be converted to matrices of
        string by later processing in ``process_element``
        '''
        '''Notes to friendly fellow-optimizer
        
        This routine is not much optimized.  If I was going to do it,
        I'd store the codecs as an object pointer array, as for the
        .dtypes, I might use python_string.PyString_Decode for decoding,
        I'd do something with pointers to pull the LSB out of the uint16
        dtype, without using an intermediate array, I guess I'd consider
        using the numpy C-API for array creation. I'd try and work out
        how to deal with UCS-2 and UCS-4 builds of python, and how numpy
        deals with unicode strings passed as memory,

        My own introduction here:
        https://cirl.berkeley.edu/mb312/pydagogue/python_unicode.html
        '''
        cdef:
            cnp.uint32_t mdtype, byte_count
            char *data_ptr
            size_t el_count
            object data, res, codec
            cnp.ndarray arr
        cdef size_t length = self.size_from_header(header)
        data = self.read_element(
            &mdtype, &byte_count, <void **>&data_ptr, True)
        # Character data can be of apparently numerical types,
        # specifically np.uint8, np.int8, np.uint16.  np.unit16 can have
        # a length 1 type encoding, like ascii, or length 2 type
        # encoding
        cdef cnp.dtype dt = <cnp.dtype>self.dtypes[mdtype]
        if mdtype == miUINT16:
            codec = self.uint16_codec
            if self.codecs['uint16_len'] == 1: # need LSBs only
                arr = np.ndarray(shape=(length,),
                                  dtype=dt,
                                  buffer=data)
                data = arr.astype(np.uint8).tostring()
        elif mdtype == miINT8 or mdtype == miUINT8:
            codec = 'ascii'
        elif mdtype in self.codecs: # encoded char data
            codec = self.codecs[mdtype]
            if not codec:
                raise TypeError('Do not support encoding %d' % mdtype)
        else:
            raise ValueError('Type %d does not appear to be char type'
                             % mdtype)
        uc_str = data.decode(codec)
        # cast to array to deal with 2, 4 byte width characters
        arr = np.array(uc_str)
        dt = self.U1_dtype
        # could take this to numpy C-API level, but probably not worth
        # it
        print 'hds %s, uc_str "%s"' % (header.dims, uc_str)
        return np.ndarray(shape=header.dims,
                          dtype=dt,
                          buffer=arr,
                          order='F')
                             
    cpdef cnp.ndarray read_cells(self, VarHeader5 header):
        ''' Read cell array from stream '''
        cdef:
            size_t i
            cnp.ndarray[object, ndim=1] result
        # Account for fortran indexing of cells
        tupdims = tuple(header.dims[::-1])
        cdef size_t length = self.size_from_header(header)
        result = np.empty(length, dtype=object)
        for i in range(length):
            result[i] = self.read_mi_matrix()
        return result.reshape(tupdims).T
        
    cpdef cnp.ndarray read_struct(self, VarHeader5 header):
        ''' Read struct or object array from stream

        Objects are just structs with an extra field *classname*,
        defined before (this here) struct format structure
        '''
        cdef:
            cnp.int32_t namelength
            int i, n_names
            cnp.ndarray rec_res
            cnp.ndarray[object, ndim=1] result
            object name, field_names, dt, tupdims
        # Read field names into list
        cdef int res = self.read_into_int32s(&namelength)
        if res != 1:
            raise ValueError('Only one value for namelength')
        cdef object names = self.read_int8_string()
        field_names = []
        n_names = PyString_Size(names) // namelength
        cdef char *n_ptr = names
        for i in range(n_names):
            name = PyString_FromString(n_ptr)
            field_names.append(name)
            n_ptr += namelength
        # Prepare struct array
        tupdims = tuple(header.dims[::-1])
        cdef size_t length = self.size_from_header(header)
        if self.struct_as_record: # to record arrays
            if not n_names:
                # If there are no field names, there is no dtype
                # representation we can use, falling back to empty
                # object
                return np.empty(tupdims, dtype=object).T
            dt = [(field_name, object) for field_name in field_names]
            rec_res = np.empty(length, dtype=dt)
            for i in range(length):
                for field_name in field_names:
                    rec_res[i][field_name] = self.read_mi_matrix()
            return rec_res.reshape(tupdims).T
        # Backward compatibility with previous format
        obj_template = mio5p.mat_struct()
        obj_template._fieldnames = field_names
        result = np.empty(length, dtype=object)
        for i in range(length):
            item = pycopy(obj_template)
            for name in field_names:
                item.__dict__[name] = self.read_mi_matrix()
            result[i] = item
        return result.reshape(tupdims).T


