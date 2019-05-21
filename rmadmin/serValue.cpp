#include <iostream>
#include <cstring>
#include "confValue.h"
#include "serValue.h"

namespace ser {

Value::Value(ValueType type_) : type(type_) {}

Value::~Value() {}

int Value::numColumns() const
{
  return 1;
}

Value const *Value::columnValue(int c) const
{
  assert(c == 0);
  return this;
}

bool Value::operator==(Value const &other) const
{
  return other.type == type;
}

bool Value::operator!=(Value const &other) const
{
  return !operator==(other);
}

std::ostream &operator<<(std::ostream &os, Value const &v)
{
  os << v.toQString().toStdString();
  return os;
}

// Returns the number of words required to store that many bytes:
static size_t roundUpWords(size_t sz)
{
  return (sz + 3) >> 2;
}

Null::Null() : Value(AnyType) {}

Error::Error(QString const &errMsg_) : Value(EmptyType), errMsg(errMsg_) {}

QString Null::toQString() const
{
  return QString("NULL");
}

Float::Float(uint32_t const *&start) : Value(FloatType)
{
  static_assert(sizeof(double) <= 2 * sizeof(uint32_t));
  memcpy(&v, start, sizeof(v));
  std::cout << "float = " << v << std::endl;
  start += 2;
}

QString Float::toQString() const
{
  return QString::number(v);
}

Bool::Bool(uint32_t const *&start) : Value(BoolType)
{
  v = !! *start;
  std::cout << "bool = " << v << std::endl;
  start += 1;
}

QString Bool::toQString() const
{
  if (v) return QString(QCoreApplication::translate("QMainWindow", "true"));
  else return QString(QCoreApplication::translate("QMainWindow", "false"));
}

String::String(uint32_t const *&start, size_t len) : Value(StringType)
{
  char const *c = (char const *)start;
  for (size_t i = 0; i < len; i++) {
    v.append(QChar(c[i]));
  }
  std::cout << "string = " << v.toStdString() << std::endl;
  start += roundUpWords(len);
}

U8::U8(uint32_t const *&start) : Value(U8Type)
{
  v = *(uint8_t const *)start;
  std::cout << "u8 = " << v << std::endl;
  start += 1;
}

U16::U16(uint32_t const *&start) : Value(U16Type)
{
  v = *(uint16_t const *)start;
  std::cout << "u16 = " << v << std::endl;
  start += 1;
}

U32::U32(uint32_t const *&start) : Value(U32Type)
{
  v = *(uint32_t const *)start;
  std::cout << "u32 = " << v << std::endl;
  start += 1;
}

U64::U64(uint32_t const *&start) : Value(U64Type)
{
  v = *(uint64_t const *)start;
  std::cout << "u64 = " << v << std::endl;
  start += 2;
}

U128::U128(uint32_t const *&start) : Value(U128Type)
{
  v = *(uint128_t const *)start;
  std::cout << "u128 = xyz" << std::endl;
  start += 4;
}

I8::I8(uint32_t const *&start) : Value(I8Type)
{
  v = *(int8_t const *)start;
  std::cout << "i8 = " << v << std::endl;
  start += 1;
}

I16::I16(uint32_t const *&start) : Value(I16Type)
{
  v = *(int16_t const *)start;
  std::cout << "i16 = " << v << std::endl;
  start += 1;
}

I32::I32(uint32_t const *&start) : Value(I32Type)
{
  v = *(int32_t const *)start;
  std::cout << "i32 = " << v << std::endl;
  start += 1;
}

I64::I64(uint32_t const *&start) : Value(I64Type)
{
  v = *(int64_t const *)start;
  std::cout << "i64 = " << v << std::endl;
  start += 2;
}

I128::I128(uint32_t const *&start) : Value(I128Type)
{
  v = *(int128_t const *)start;
  std::cout << "i128 = xxx" << std::endl;
  start += 4;
}

Eth::Eth(uint32_t const *&start) : Value(EthType)
{
  v = *(uint64_t const *)start;
  std::cout << "eth = " << v << std::endl;
  start += 2;
}

Ipv4::Ipv4(uint32_t const *&start) : Value(Ipv4Type)
{
  v = *(uint64_t const *)start;
  std::cout << "ipv4 = " << v << std::endl;
  start += 2;
}

Ipv6::Ipv6(uint32_t const *&start) : Value(Ipv6Type)
{
  v = *(uint128_t const *)start;
  std::cout << "ipv6 = xyz" << std::endl;
  start += 4;
}

Tuple::Tuple(std::vector<Value const *> const &fieldValues_) :
  Value(TupleType), fieldValues(fieldValues_) {}

QString Tuple::toQString() const
{
  QString s("(");
  for (unsigned i = 0; i < fieldValues.size(); i++) {
    if (i > 0) s += "; ";
    s += fieldValues[i]->toQString();
  }
  s += ")";
  return s;
}

Vec::Vec(std::vector<Value const *> const &values_) :
  Value(VecType), values(values_) {}

QString Vec::toQString() const
{
  QString s("[");
  for (unsigned i = 0; i < values.size(); i++) {
    if (i > 0) s += "; ";
    s += values[i]->toQString();
  }
  s += "]";
  return s;
}

Record::Record(std::vector<std::pair<QString, Value const *>> const &fieldValues_) :
  Value(RecordType), fieldValues(fieldValues_) {}

QString Record::toQString() const
{
  QString s("{");
  for (unsigned i = 0; i < fieldValues.size(); i++) {
    if (i > 0) s += "; ";
    s += fieldValues[i].first + ":" + fieldValues[i].second->toQString();
  }
  s += "}";
  return s;
}

// TODO: an actual object with an end to check against
static bool bitSet(unsigned char const *nullmask, unsigned null_i)
{
  if (null_i >= 8) return bitSet(nullmask + 1, null_i - 8);
  else return (*nullmask) & (1 << null_i);
}

Value *unserialize(std::shared_ptr<conf::RamenType const> type, uint32_t const *&start, uint32_t const *max, bool topLevel)
{
  // DEBUG
  std::cout << "unserialize type " << *type << std::endl;
  for (uint32_t const *c = start; c < max; c++) {
    std::cout << (c - start) << ": " << *c << std::endl;
  }

  // TODO top-level output value that can be NULL
  assert(!topLevel || !type->nullable);

  ValueType const valueType = type->type;
  switch (valueType) {
    case FloatType:
      if (start + 2 > max) return new Error("Cannot unserialize float");
      return new Float(start);
    case StringType:
      {
        if (start + 1 > max) return new Error("Cannot unserialize string");
        size_t const len = *(start++);
        size_t const wordLen = roundUpWords(len);
        if (start + wordLen > max)
          return new Error("Cannot unserialize of length " +
                           QString::number(len));
        return new String(start, len);
      }
    case BoolType:
      if (start + 1 > max) return new Error("Cannot unserialize bool");
      return new Bool(start);
    case U8Type:
      if (start + 1 > max) return new Error("Cannot unserialize u8");
      return new U8(start);
    case U16Type:
      if (start + 1 > max) return new Error("Cannot unserialize u16");
      return new U16(start);
    case U32Type:
      if (start + 1 > max) return new Error("Cannot unserialize u32");
      return new U32(start);
    case I8Type:
      if (start + 1 > max) return new Error("Cannot unserialize i8");
      return new I8(start);
    case I16Type:
      if (start + 1 > max) return new Error("Cannot unserialize i16");
      return new I16(start);
    case I32Type:
      if (start + 1 > max) return new Error("Cannot unserialize i32");
      return new I32(start);
    case Ipv4Type:
      if (start + 1 > max) return new Error("Cannot unserialize ipv4");
      return new Ipv4(start);
    case U64Type:
      if (start + 2 > max) return new Error("Cannot unserialize u64");
      return new U64(start);
    case I64Type:
      if (start + 2 > max) return new Error("Cannot unserialize i64");
      return new I64(start);
    case EthType:
      if (start + 2 > max) return new Error("Cannot unserialize eth");
      return new Eth(start);
    case U128Type:
      if (start + 4 > max) return new Error("Cannot unserialize u128");
      return new U128(start);
    case I128Type:
      if (start + 4 > max) return new Error("Cannot unserialize i128");
      return new I128(start);
    case Ipv6Type:
      if (start + 4 > max) return new Error("Cannot unserialize ipv6");
      return new Ipv6(start);
    case IpType:
    case Cidrv4Type:
    case Cidrv6Type:
    case CidrType:
      // TODO
      return new Error("TODO: unserialize");
    case TupleType:
      {
        std::shared_ptr<conf::RamenTypeTuple const> tuple =
          std::dynamic_pointer_cast<conf::RamenTypeTuple const>(type);
        if (!tuple) {
          std::cout << "Tuple is not a tuple." << std::endl;
          return new Error("Cannot unserialize: Invalid tag for tuple");
        }
        size_t const nullmaskWidth = type->nullmaskWidth(topLevel);
        unsigned char *nullmask = (unsigned char *)start;
        start += roundUpWords(nullmaskWidth);
        if (start > max) return new Error("Invalid start/max");
        unsigned null_i = 0;
        std::vector<Value const *> fieldValues;
        fieldValues.reserve(tuple->fields.size());
        for (auto &subType : tuple->fields) {
          if (subType->nullable) {
            fieldValues.push_back(
              bitSet(nullmask, null_i) ?
                unserialize(subType, start, max) :
                new Null()
            );
            null_i++;
          } else {
            fieldValues.push_back(
              unserialize(subType, start, max)
            );
          }
        }
        return new Tuple(fieldValues);
      }
      break;
    case VecType:
      {
        std::shared_ptr<conf::RamenTypeVec const> vec =
          std::dynamic_pointer_cast<conf::RamenTypeVec const>(type);
        if (!vec) {
          std::cout << "Vector is not a vector." << std::endl;
          return new Error("Cannot unserialize: Invalid tag for vector");
        }
        size_t const nullmaskWidth = type->nullmaskWidth(topLevel);
        unsigned char *nullmask = (unsigned char *)start;
        start += roundUpWords(nullmaskWidth);
        if (start > max) return new Error("Invalid start/max");
        unsigned null_i = 0;
        std::vector<Value const *> values;
        values.reserve(vec->dim);
        for (unsigned i = 0; i < vec->dim; i++) {
          if (vec->subType->nullable) {
            values.push_back(
              bitSet(nullmask, null_i) ?
                unserialize(vec->subType, start, max) :
                new Null()
            );
            null_i++;
          } else {
            values.push_back(
              unserialize(vec->subType, start, max)
            );
          }
        }
        return new Vec(values);
      }
      break;
    case ListType:
      // TODO
      return new Error("TODO: unserialize lists");
    case RecordType:
      {
        std::shared_ptr<conf::RamenTypeRecord const> record =
          std::dynamic_pointer_cast<conf::RamenTypeRecord const>(type);
        if (!record) {
          std::cout << "Record is not a record." << std::endl;
          return new Error("Cannot unserialize: Invalid tag for record");
        }
        size_t const nullmaskWidth = type->nullmaskWidth(topLevel);
        unsigned char *nullmask = (unsigned char *)start;
        start += roundUpWords((nullmaskWidth + 7)/8);
        if (start > max) return new Error("Invalid start/max");
        unsigned null_i = 0;
        // In user order:
        std::vector<std::pair<QString, Value const *>> fieldValues(
          record->fields.size(),
          std::make_pair(QString(), nullptr)
        );
        for (unsigned i = 0; i < record->serOrder.size(); i++) {
          size_t fieldIdx = record->serOrder[i];
          std::pair<QString, std::shared_ptr<conf::RamenType const>> const *field =
            &record->fields[ fieldIdx ];
          QString const &fieldName = field->first;
          std::shared_ptr<conf::RamenType const> subType = field->second;
          std::cout << "Next field is " << fieldName.toStdString() << ", "
                    << (subType->nullable ?
                         (bitSet(nullmask, null_i) ?
                           "not null" : "null") :
                         "not nullable") << std::endl;
          fieldValues[ fieldIdx ].first = fieldName;
          if (subType->nullable) {
            fieldValues[ fieldIdx ].second =
              bitSet(nullmask, null_i) ?
                unserialize(subType, start, max) :
                new Null();
            null_i++;
          } else {
            fieldValues[ fieldIdx ].second =
              unserialize(subType, start, max);
          }
        }
        return new Record(fieldValues);
      }
    default:
      return new Error("Cannot unserialize: unknown tag");
  }
}

};
