#ifndef TIMECHARTEDITOR_H_200306
#define TIMECHARTEDITOR_H_200306
#include <QWidget>

class QPushButton;
class QWidget;
class TimeChart;
class TimeChartEditWidget;
class TimeLineGroup;
struct TimeRange;

class TimeChartEditor : public QWidget
{
  Q_OBJECT

public:
  TimeChartEditWidget *editWidget;
  TimeChart *chart;
  QWidget *timeLines;

  TimeChartEditor(
    QPushButton *submitButton,
    QPushButton *cancelButton,
    TimeLineGroup *timeLineGroup,
    QWidget *parent = nullptr);

signals:
  void timeRangeChanged(TimeRange const &);
  void newTailTime(double);
};

#endif
