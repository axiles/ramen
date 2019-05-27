#include <memory>
#include <QString>
#include "FunctionItem.h"
#include "conf.h"
#include "confValue.h"
#include "ChartDataSet.h"

ChartDataSet::ChartDataSet(FunctionItem const *functionItem_, unsigned column_, QObject *parent) :
  QObject(parent), functionItem(functionItem_), column(column_), isFactor(false)
{
  std::shared_ptr<conf::RamenType const> outType = functionItem->outType();
  type = outType->columnType(column);
  QString const name = outType->columnName(column);

  // Retrieve whether this column is a factor:
  conf::kvs_lock.lock_shared();
  for (unsigned i = 0; i < 1000; i++) {
    conf::Key k = functionItem->functionKey("/factors/" + std::to_string(i));
    auto const &it = conf::kvs.find(k);
    if (it == conf::kvs.end()) break;
    std::shared_ptr<conf::Value const> v_(it.value().value());
    std::shared_ptr<conf::String const> v =
      std::dynamic_pointer_cast<conf::String const>(v_);
    if (! v) {
      std::cout << "Factor #" << i << " is not a string!?" << std::endl;
      continue;
    }
    if (v->toQString() == name) {
      isFactor = true;
      break;
    }
  }
  conf::kvs_lock.unlock_shared();
}

bool ChartDataSet::isNumeric() const
{
  return type->isNumeric();
}
