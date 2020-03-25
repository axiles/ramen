#ifndef TIMECHARTFUNCTIONEDITOR_H_200306
#define TIMECHARTFUNCTIONEDITOR_H_200306
#include <memory>
#include <string>
#include <QSize>
#include <QWidget>
#include "confValue.h"  // for the inner DashboardWidgetChart::Source

class KValue;
class QCheckBox;
class QLineEdit;
class QPushButton;
class QTableView;
class TimeChartFunctionFieldsModel;
namespace conf {
  class Automaton;
};

class TimeChartFunctionEditor : public QWidget
{
  Q_OBJECT

public:
  QCheckBox *visible;   // To disable the whole source temporarily
  QPushButton *customize;
  QPushButton *openSource;

  QTableView *fields;

  TimeChartFunctionFieldsModel *model;

  TimeChartFunctionEditor(
    std::string const &site,
    std::string const &program,
    std::string const &function,
    bool customizable = true,  // TODO: disable this for the raw config editor
    QWidget *parent = nullptr);

protected slots:
  void wantSource();
  void wantCustomize();
  void automatonTransition(
    conf::Automaton *, size_t, std::shared_ptr<conf::Value const>);

public slots:
  void setEnabled(bool);
  bool setValue(conf::DashWidgetChart::Source const &);
  conf::DashWidgetChart::Source getValue() const;

signals:
  void fieldChanged(std::string const &site, std::string const &program,
                    std::string const &function, std::string const &name);
  void customizedFunction(std::string const &site, std::string const &program,
                          std::string const &function);
};

#endif
