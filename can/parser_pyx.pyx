# distutils: language = c++
# cython: c_string_encoding=ascii, language_level=3

from libcpp.string cimport string
from libcpp.vector cimport vector
from libcpp.unordered_set cimport unordered_set
from libc.stdint cimport uint32_t, uint64_t, uint16_t
from libcpp.map cimport map
from libcpp cimport bool

from .common cimport CANParser as cpp_CANParser
from .common cimport SignalParseOptions, MessageParseOptions, dbc_lookup, SignalValue, DBC, Signal

import os
import numbers
from collections import defaultdict

cdef int CAN_INVALID_CNT = 5

cdef class CANParser:
  cdef:
    cpp_CANParser *can
    const DBC *dbc
    map[string, uint32_t] msg_name_to_address
    map[uint32_t, string] address_to_msg_name
    vector[SignalValue] can_values
    bool test_mode_enabled

  cdef readonly:
    string dbc_name
    dict vl
    dict ts
    dict info
    bool can_valid
    int can_invalid_cnt

  def __init__(self, dbc_name, signals, checks=None, bus=0, enforce_checks=True):
    if checks is None:
      checks = []
    self.dbc_name = dbc_name
    self.dbc = dbc_lookup(dbc_name)
    if not self.dbc:
      raise RuntimeError(f"Can't find DBC: {dbc_name}")

    self.vl = {}
    self.ts = {}
    self.can_valid = True
    self.can_invalid_cnt = CAN_INVALID_CNT

    for i in range(self.dbc[0].num_msgs):
      msg = self.dbc[0].msgs[i]
      name = msg.name.decode('utf8')

      self.msg_name_to_address[name] = msg.address
      self.address_to_msg_name[msg.address] = name
      self.vl[msg.address] = {}
      self.vl[name] = {}
      self.ts[msg.address] = {}
      self.ts[name] = {}
      self.info[msg.address] = {}
      self.info[name] = {}

      for x in range(msg.num_sigs):
        sig = msg.sigs[x]
        sig_name = sig.name.decode('utf8')
        self.info[name][sig_name] = {"is_signed": sig.is_signed, "scale": sig.factor, "offset": sig.offset, "is_little_endian": sig.is_little_endian}

    # Convert message names into addresses
    for i in range(len(signals)):
      s = signals[i]
      if not isinstance(s[1], numbers.Number):
        name = s[1].encode('utf8')
        s = (s[0], self.msg_name_to_address[name], s[2])
        signals[i] = s

    for i in range(len(checks)):
      c = checks[i]
      if not isinstance(c[0], numbers.Number):
        name = c[0].encode('utf8')
        c = (self.msg_name_to_address[name], c[1])
        checks[i] = c

    if enforce_checks:
      checked_addrs = {c[0] for c in checks}
      signal_addrs = {s[1] for s in signals}
      unchecked = signal_addrs - checked_addrs
      if len(unchecked):
        err_msg = ', '.join(f"{self.address_to_msg_name[addr].decode()} ({hex(addr)})" for addr in unchecked)
        raise RuntimeError(f"Unchecked addrs: {err_msg}")

    cdef vector[SignalParseOptions] signal_options_v
    cdef SignalParseOptions spo
    for sig_name, sig_address, sig_default in signals:
      spo.address = sig_address
      spo.name = sig_name
      spo.default_value = sig_default
      signal_options_v.push_back(spo)

    message_options = dict((address, 0) for _, address, _ in signals)
    message_options.update(dict(checks))

    cdef vector[MessageParseOptions] message_options_v
    cdef MessageParseOptions mpo
    for msg_address, freq in message_options.items():
      mpo.address = msg_address
      mpo.check_frequency = freq
      message_options_v.push_back(mpo)

    self.can = new cpp_CANParser(bus, dbc_name, message_options_v, signal_options_v)
    self.update_vl()

  cdef unordered_set[uint32_t] update_vl(self):
    cdef string sig_name
    cdef unordered_set[uint32_t] updated_val

    can_values = self.can.query_latest()
    valid = self.can.can_valid

    # Update invalid flag
    self.can_invalid_cnt += 1
    if valid:
        self.can_invalid_cnt = 0
    self.can_valid = self.can_invalid_cnt < CAN_INVALID_CNT

    for cv in can_values:
      # Cast char * directly to unicode
      name = <unicode>self.address_to_msg_name[cv.address].c_str()
      cv_name = <unicode>cv.name

      self.vl[cv.address][cv_name] = cv.value
      self.ts[cv.address][cv_name] = cv.ts

      self.vl[name][cv_name] = cv.value
      self.ts[name][cv_name] = cv.ts

      updated_val.insert(cv.address)

    return updated_val

  def update_string(self, dat, sendcan=False):
    self.can.update_string(dat, sendcan)
    return self.update_vl()

  def update_strings(self, strings, sendcan=False):
    updated_vals = set()

    for s in strings:
      updated_val = self.update_string(s, sendcan)
      updated_vals.update(updated_val)

    return updated_vals

cdef class CANDefine():
  cdef:
    const DBC *dbc

  cdef readonly:
    dict dv
    dict info
    string dbc_name

  def __init__(self, dbc_name):
    self.dbc_name = dbc_name
    self.dbc = dbc_lookup(dbc_name)
    if not self.dbc:
      raise RuntimeError(f"Can't find DBC: '{dbc_name}'")

    address_to_msg_name = {}

    for i in range(self.dbc[0].num_msgs):
      msg = self.dbc[0].msgs[i]
      address_to_msg_name[msg.address] = msg.name.decode('utf8')

    dv = defaultdict(dict)
    for i in range(self.dbc[0].num_vals):
      val = self.dbc[0].vals[i]

      sig_name = val.name.decode('utf8')
      address = val.address
      def_val = val.def_val.decode('utf8')
      msg_name = address_to_msg_name[address]

      # separate definition/value pairs
      def_val = def_val.split()
      values = [int(v) for v in def_val[::2]]
      defs = def_val[1::2]

      # also get information like scale, offset, etc
      print(sig_name)
      print(val.sigs[val.sig_idx].name)
      print()
      #for x in range(val.sig):
      #  print(val.sigs[x])

      # two ways to lookup: address or msg name
      dv[address][sig_name] = dict(zip(values, defs))
      dv[msg_name][sig_name] = dv[address][sig_name]
      #info[address][sig_name] = {}
      #info[msg_name][sig_name] = info[address][sig_name]

    it = 0
    info = defaultdict(dict)
    for i in range(self.dbc[0].num_msgs):
      msg = self.dbc[0].msgs[i]
      msg_name = msg.name.decode('utf8')

      for x in range(msg.num_sigs):
        it += 1
        sig = msg.sigs[x]
        sig_name = sig.name.decode('utf8')
        info[address][sig_name] = {"is_signed": sig.is_signed, "scale": sig.factor, "offset": sig.offset, "is_little_endian": sig.is_little_endian}
        info[msg_name][sig_name] = info[address][sig_name]

    print(it)
    self.dv = dict(dv)
    self.info = dict(info)
